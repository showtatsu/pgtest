package PgTest;

# * Import CGI Application and plugins.
use base qw(CGI::Application);
use CGI::Application::Plugin::DBH qw(dbh_config dbh);
use CGI::Application::Plugin::Session;
use CGI::Application::Plugin::TT;
use FindBin;
use File::Basename qw();
use Encode qw();
use Redis;
use YAML::Syck;
use utf8;
use strict;
use warnings;

# * Package parameters.

# - SOURCE_CODE_ENCODING
#    The encoding of the scripts and templates.
#    Also used as a default charset.
our $SOURCE_CODE_ENCODING = 'utf-8';

# - AVAILABLE_ENCODING
#    A regexp pattern for charsets which are available or not.
#    Also used as a default charset.
our $AVAILABLE_ENCODING = qr/^(utf-8|euc-jp|shift_jis|iso-8859-1)$/;

# - CONFIG_FILE
#    The default path of configuration file.
our $CONFIG_FILE = "$FindBin::Bin/conf/Config.pgtest.yaml";

# - VIEW_TEMPLATES
#    A hashed map for finding templates.
our %VIEW_TEMPLATES = (
    main => "$FindBin::Bin/tt/view.tt.html",
    error => "$FindBin::Bin/tt/error.tt.html",
);

# - post_validator
#    A hashed map of validators to check POST parameters.
#    If a parameter is acceptable, the validator will return undef.
#    Otherwise, it will return an error message.
my %post_validator = (
    id => sub {
        my ($value, $context) = @_;
        return if ("$value" =~ m/^[0-9]{1,10}$/);
        return "param:id must be a number"
    },
    entry_meta => sub {
        my ($value, $context) = @_;
        return 'param:entry_meta contains UNICODE::cntrl chars.'
            if ("$value" =~ m/(?![\r\n])[[:cntrl:]]/);
        return;
    },
    entry_text => sub {
        my ($value, $context) = @_;
        return 'param:entry_text contains UNICODE::cntrl chars.'
            if ("$value" =~ m/(?![\r\n])[[:cntrl:]]/);
        return;
    },
    purge => sub {
        my ($value, $context) = @_;
        return 'param:purge must "purge".'
            if ("$value" =~ m/(purge)$/);
        return;
    },
);

# - cgiapp_init (overrides CGI::Application)
#   パッケージコンストラクタの引数を処理します。
sub cgiapp_init {
    my $self = shift;
    my %option = @_;
    $self->{config_file} = $option{config_file} || $CONFIG_FILE;
}

# - setup (overrides CGI::Application)
#   CGI::Applicationが初期化されるときに一度実行されます。
#   コンフィグファイルを読み込み、データベース(PostgreSQL)、
#   セッションストア(Redis KVS)への接続を初期化します。
sub setup {
    my $self = shift;

    # - Allow HTML::Template to use abs path access.
    #   Be careful to modify code.
    # 内部的にすべて[utf8 flagged]で処理するため、TTの読み込み時に
    # decodeが必要です(UNICODEオプションがこれに相当します)
    $self->tt_config(TEMPLATE_OPTIONS => +{
            ABSOLUTE => 1,
            UNICODE => 1,
            ENCODING => $SOURCE_CODE_ENCODING,
        });
    # - Build CGI application map.
    $self->_setup_route;
    # setup中の例外をcacheしてテンプレート処理を行うのであれば、
    # テンプレート処理に必要な処理は、当然evalするよりも先に
    # 終わらせておく必要があります。(tt_config、run_modeの設定など)
    eval {
        # - Load external connections' metadata from config file.
        my $config = $self->_setup_loadfile($self->{config_file});
        my $config_app = $config->{application} || +{};
        # path_infoを使うCGI::Applicationで面倒なのは相対パスの管理です。
        # 環境変数:SCRIPT_NAME は、実行中のコードベースの位置
        # (このソースコードのパス)を指すはずなので、ここを起点にします。
        $self->{root_url} = $config_app->{root_url}
                || File::Basename::dirname($ENV{SCRIPT_NAME});
        # - Build database connection
        my $config_dbh = $config->{database};
        $self->_setup_dbh(%$config_dbh);
        # - Build connection for redis session store.
        my $config_session = $config->{session_store};
        $config_session->{cookie_path} = $self->{root_url}
            unless $config_session->{cookie_path};
        $self->_setup_session(%$config_session);
    };
    # - Set error message if setup failed.
    $self->{setup_failed} = $@ if $@;
}

# - setup_failed
#   setup 処理中に発生した例外を返します。
#   setup処理をdieで終了させてしまうとフレームワークが
#   デバッグメッセージを表示してしまうため、例外を補足して
#   表示をコントロールするために一時的に保管します。
sub setup_failed {
    my $self = shift;
    return $self->{setup_failed};
}

# + Database access methods

# * database_fetch_for_tt
#   - returns: Array of hashrefs. TT/HTML formated.
sub database_fetch_for_tt {
    my $self = shift;
    # - Fetch data from database.
    my $fetched = [];
    my ($record_id, $record_meta, $record_text);
    my $dbh = eval { $self->dbh; };
    Carp::confess($@) if $@;
    Carp::confess("failed to connect database") unless $dbh;
    my $sth = $dbh->prepare(q{SELECT * FROM test});
    $sth->execute;
    # DBI(Pg::DBD)から戻ってきた値を処理します。
    # [pg_enable_utf8=1]のため、fetchされた時点ですでに[utf8 flagged]です。
    $sth->bind_columns(\$record_id, \$record_meta, \$record_text);
    my $q = $self->query;
    # HTML::Templateと違いTemplate ToolkitはHTMLエスケープ機能を持ちません。
    # (この関数はTT用入力を作るまでが責任なので、)関数から返す前にescapeしておきます。
    push(@$fetched, +{
            data_id => $q->escapeHTML($record_id),
            data_meta => $q->escapeHTML($record_meta),
            data_text => $q->escapeHTML($record_text),
        }) while($sth->fetch);
    return $fetched;
}

# * database_insert_item
#   - returns: count of last inserted records (may be 1).
sub database_insert_item {
    my $self = shift;
    my ($q_id, $q_meta, $q_text) = @_;
    my $dbh = eval { $self->dbh; };
    Carp::confess($@) if $@;
    Carp::confess("failed to connect database") unless $dbh;
    my $sth = $dbh->prepare(q{INSERT INTO test VALUES (?, ?, ?)});
    # コード内は原則[utf8 flagged]で回っているはずなので、
    # ポリシー通りであれば、ここでのdecodeは不要のはずです。
    $sth->execute($q_id, $q_meta, $q_text);
    my $count = $sth->rows;
    $sth->finish;
    return $count;
}

# * database_purge_item
#   - returns: count of last inserted records (may be 1).
sub database_purge_item {
    my $self = shift;
    my $dbh = eval { $self->dbh; };
    Carp::confess($@) if $@;
    Carp::confess("failed to connect database") unless $dbh;
    my $sth = $dbh->prepare(q{DELETE FROM test});
    $sth->execute;
    my $count = $sth->rows;
    $sth->finish;
    return $count;
}


# + Mounted actions for this CGI::Application.

sub action_show {
    my $self = shift;
    # setup 中に発生した例外をコントロールするために、
    # 各actionの最初でエラー有無を確認します。
    Carp::confess($self->setup_failed) if $self->setup_failed;
    # - Build CGI object and read parameters.
    my $q = $self->query;
    my $encode = $self->encoding;

    # - Fetch data from database.
    my $fetched = eval { $self->database_fetch_for_tt; };
    # - Show error page if database access failed.
    Carp::confess($@) if $@;
    
    # - Build HTML
    my $build_parameter = +{
        charset => $encode,
        root_url => $self->{root_url},
        script_name => $ENV{SCRIPT_NAME},
        data_list => $fetched,
    };
    $self->set_http_header;
    my $document = $self->tt_process($VIEW_TEMPLATES{main}, $build_parameter);
    return Encode::encode($encode, $$document);
}

sub action_insert {
    my $self = shift;
    # - Show error page if the setup was failed.
    Carp::confess($self->setup_failed) if $self->setup_failed;
    # - Build CGI object and read parameters.
    my $q = $self->query;
    my $encode = $self->encoding;
    my ($param_error, $q_id, $q_meta, $q_text) = $self->_query_params(
            [qw(id entry_meta entry_text)], 'insert', $encode
        );
    Carp::confess($param_error) if $param_error;
    
    my $build_parameter = +{
        charset => $encode,
        root_url => $self->{root_url},
        script_name => $ENV{SCRIPT_NAME},
    };
    # - Check: Is a POST action ?
    if($q_id and $q_meta and $q_text) {
        # YES: User wanna update entries.
        # 2.Check: A session of the user is ready for INSERT ?
        if ($self->session->param('ready.insert')) {
            # 2.YES: ready.
            eval { $self->database_insert_item($q_id, $q_meta, $q_text); };
            Carp::confess($@) if $@;
            # use utf8;環境下なので、文字列リテラルは既に[utf8 flagged]
            $self->session->param('ready.insert', undef);
            $build_parameter->{message} = "レコード作成に成功しました！";
        } else {
            Carp::confess("セッションタイムアウト、又は不正なページ遷移です");
        }
    } else {
        $self->session->param('ready.insert', 1);
        $build_parameter->{SHOW_INSERT} = 1;
    }
    # - Fetch data from database.
    $build_parameter->{data_list} = eval { $self->database_fetch_for_tt; };
    # - Show error page if database access failed.
    Carp::confess($@) if $@;
    # - Build HTML
    $self->set_http_header;
    my $document = $self->tt_process($VIEW_TEMPLATES{main}, $build_parameter);
    return Encode::encode($encode, $$document);
}

sub action_purge {
    my $self = shift;
    # - Show error page if the setup was failed.
    Carp::confess($self->setup_failed) if $self->setup_failed;
    # - Build CGI object and read parameters.
    my $q = $self->query;
    my $encode = $self->encoding;
    my ($param_error, $q_confirm) = $self->_query_params(
            [qw(purge)], 'purge', $encode
        );
    Carp::confess($param_error) if $param_error;
    
    my $build_parameter = +{
        charset => $encode,
        root_url => $self->{root_url},
        script_name => $ENV{SCRIPT_NAME},
    };
    # - Check: Is a POST action ?
    if ($q_confirm) {
        # YES: User wanna update entries.
        # 2.Check: A session of the user is ready for DELETE ?
        if ($self->session->param('ready.purge')) {
            $self->session->param('ready.purge', undef);
            $self->database_purge_item();
            $build_parameter->{message} = '値の削除に成功しました';
        } else {
            Carp::confess("セッションタイムアウト、又は不正なページ遷移です");
        }
    } else {
        $self->session->param('ready.purge', 1);
        $build_parameter->{SHOW_PURGE} = 1;
    }
    # - Fetch data from database.
    $build_parameter->{data_list} = eval { $self->database_fetch_for_tt; };
    # - Show error page if database access failed.
    Carp::confess($@) if $@;
    # - Build HTML
    $self->set_http_header;
    my $document = $self->tt_process($VIEW_TEMPLATES{main}, $build_parameter);
    return Encode::encode($encode, $$document);
}

sub action_unknown {
    my $self = shift;
    my $spec_runmode = shift;
    Carp::confess($self->setup_failed) if $self->setup_failed;
    Carp::confess("Action [$spec_runmode] is not defined", 404);
}

sub action_on_error {
    my $self = shift;
    my ($message, $code) = @_;
    my $q = $self->query;
    my $encode = $self->encoding;
    my $build_parameter = +{
        charset => $encode,
        root_url => $self->{root_url},
        script_name => $ENV{SCRIPT_NAME},
    };
    $build_parameter->{message} = $q->escapeHTML($message) if $message;
    # - Build HTML
    $self->set_http_header(status => ($code || 500));
    my $document = $self->tt_process($VIEW_TEMPLATES{error}, $build_parameter);
    return Encode::encode($encode, $$document);
}

# + DOM/HTTP build subroutines

sub set_http_header {
    my $self = shift;
    my %args = @_;

    my $charset = $args{charset} || $self->encoding;
    my $content_type = $args{type} || 'text/html';
    my $status_code = $args{status} || 200;

    $self->header_add(
        -type => $content_type,
        -charset => $charset,
        -status => $status_code,
    );
}

# + Utilities

# * encoding
#   出力に使うべきエンコーディングを取得・設定します。
#   文字コード回りの確認がメインなので、出力encodeは
#   URLパラメータで指定できるようにしています。
sub encoding {
    my $self = shift;
    my ($set_encoding) = @_;

    # 呼び出し毎に判定結果が変わってしまうのは不味いので、
    # 過去に一度でもencoding判定されていればそれを使う。
    if (not $set_encoding and not defined $self->{_encoding}) {
        my $q = $self->query;
        # URLパラメータでの指定があればそれに従う.
        # そうでなければ $SOURCE_CODE_ENCODING を使用。
        $set_encoding = ($q->url_param('encode') || $SOURCE_CODE_ENCODING);
    }
    if ($set_encoding) {
        if ($set_encoding =~ $AVAILABLE_ENCODING) {
            $self->{_encoding} = $set_encoding;
        } else {
            Carp::confess("Invalid encoding was specified, encode=[$set_encoding].");
        }
    }
    return $self->{_encoding};
}

# * _query_params
#   POSTされてくるパラメータは全て[utf8 flagged]に変換され、
#   入力文字列のパターンチェックを通す。
#   戻り値は配列。先頭にエラーの有無が入るので、引数に渡された
#   チェックリストと実際の戻り値のリストは1つずれることに注意。
#
#   my ($has_error, $foo, $bar) = $self->_query_params(['foo', 'bar'], 'show', 'utf-8');
#
sub _query_params {
    my $self = shift;
    my ($keys, $context, $encode) = @_;
    my $q = $self->query;
    $encode = $self->encoding unless $encode;
    my (@params, $error);
    foreach my $key(@$keys) {
        my $value = $q->param($key);
        if(defined $value) {
            # クエリパラメータが設定されていれば、decodeしてチェックを通す。
            $value = Encode::decode($encode, $value);
            if (my $validator = $post_validator{$key}) {
                $error = $validator->($value, $context);
                last if($error);
            }
        }
        push(@params, $value);
    }
    return ($error, @params);
}


# * Setup subcode
sub _setup_loadfile {
    my $self = shift;
    my ($path) = @_;
    my $config = YAML::Syck::LoadFile($path);
    return $config;
}

sub _setup_route {
    my $self = shift;
    # path_infoを使ってrun_modeを判定
    $self->mode_param(path_info => 1, param => 'action');
    $self->start_mode('show');
    $self->error_mode('action_on_error');
    $self->run_modes(
        show => 'action_show',
        insert => 'action_insert',
        purge => 'action_purge',
        # run_modeが一致しないときのデフォルトが「AUTOLOAD」.
        # これを設定しておかないと、CGI::Applicationが出したエラーメッセージを
        # 直接ユーザーに見せてしまうことになる。
        AUTOLOAD => 'action_unknown',
    );
}

sub _setup_dbh {
    my $self = shift;
    my %config = @_;
    my @dsopts;
    # PostgreSQLとの接続パラメータ。
    # DBIとのやり取りを常に[utf8 flagged]で行う必要がある。
    push(@dsopts, "dbname=$config{name}") if ($config{name});
    push(@dsopts, "host=$config{host}") if ($config{host});
    push(@dsopts, "port=$config{port}") if ($config{port});
    my $data_source = "dbi:Pg:" . join(';', @dsopts);
    my $options = +{
        # DBD::Pgからの入力を自動でutf-8にでコードする。
        pg_enable_utf8 => 1,
        AutoCommit => 1,
        RaiseError => 1,
        # Apacheのerror_logにUTF-8吐くとエスケープされる。一応戻せるし、それでも良ければ。
        PrintError => 0,
        # ShowErrorStatementは化ける。ハンドルする場所も見つからない。
        ShowErrorStatement => 0,
        # そのままRaiseErrorすると、[pg_enable_utf8=1]なのにバイナリで例外が飛んでくる.
        # HandleErrorをかませるとその引数には[utf8 flagged]でくるので、変換不要でも挟む方がよい？
        HandleError => sub { Carp::confess(shift); },
    };
    return $self->dbh_config(
            $data_source, $config{user}, $config{pass}, $options
        );
}

sub _setup_session {
    my $self = shift;
    my %config = @_;
    # session管理にはredisを使用することにしてみた.
    # cookieでセッションキーをやり取りして、データはredisに保存する。
    # Expireを設定しておけば時間が過ぎたセッションデータは勝手に消える。
    # CGI::Session::Driver::redisの公式ドキュメントはスペル間違ってるので注意.
    my $redis = Redis->new(
        server => "$config{host}:$config{port}"
    );
    my $q = $self->query;
    return $self->session_config(
        CGI_SESSION_OPTIONS => [
            'driver:redis', $q, +{
                Redis => $redis,
                Expire => $config{expire},
                Prefix => $config{prefix},
            },
        ],
        COOKIE_PARAMS => +{
            -path => $config{cookie_path},
            -expires => '+120s',
        },
        SEND_COOKIE => 1,
    );
}

1;
