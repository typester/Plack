package Plack::Builder;
use strict;
use parent qw( Exporter );
our @EXPORT = qw( builder add enable enable_if mount );

use Carp ();
use Plack::App::URLMap;
use Plack::Middleware::Conditional; # TODO delayed load?

sub new {
    my $class = shift;
    bless { middlewares => [ ] }, $class;
}

sub add_middleware {
    my($self, $mw, @args) = @_;

    if (ref $mw ne 'CODE') {
        my $mw_class = Plack::Util::load_class($mw, 'Plack::Middleware');
        $mw = sub { $mw_class->wrap($_[0], @args) };
    }

    push @{$self->{middlewares}}, $mw;
}

sub add_middleware_if {
    my($self, $cond, $mw, @args) = @_;

    if (ref $mw ne 'CODE') {
        my $mw_class = Plack::Util::load_class($mw, 'Plack::Middleware');
        $mw = sub { $mw_class->wrap($_[0], @args) };
    }

    push @{$self->{middlewares}}, sub {
        Plack::Middleware::Conditional->wrap($_[0], condition => $cond, builder => $mw);
    };
}

# do you want remove_middleware() etc.?

sub _mount {
    my ($self, $location, $app) = @_;

    if (!$self->{_urlmap}) {
        $self->{_urlmap} = Plack::App::URLMap->new;
    }

    $self->{_urlmap}->map($location => $app);
    $self->{_urlmap};
}

sub to_app {
    my($self, $app) = @_;

    for my $mw (reverse @{$self->{middlewares}}) {
        $app = $mw->($app);
    }

    $app;
}

# DSL goes here
our $_add = our $_add_if = our $_mount = sub {
    Carp::croak("enable/mount should be called inside builder {} block");
};

sub add      { Carp::carp("add is deprecated. Use 'enable'"); $_add->(@_) }
sub enable         { $_add->(@_) }
sub enable_if(&$@) { $_add_if->(@_) }

sub mount {
    my $self = shift;
    if (Scalar::Util::blessed($self)) {
        $self->_mount(@_);
    }else{
        $_mount->($self, @_);
    }
}

sub builder(&) {
    my $block = shift;

    my $self = __PACKAGE__->new;

    my $mount_is_called;
    my $urlmap = Plack::App::URLMap->new;
    local $_mount = sub {
        $mount_is_called++;
        $urlmap->map(@_);
        $urlmap;
    };
    local $_add = sub {
        $self->add_middleware(@_);
    };
    local $_add_if = sub {
        $self->add_middleware_if(@_);
    };

    my $app = $block->();
    if ($mount_is_called && $app ne $urlmap) {
        Carp::carp("You used mount() in a builder block, but the last line (app) isn't using mount().\n" .
                       "This causes all mount() mappings to be ignored. See perldoc Plack::Builder for details.");
    }

    $self->to_app($app);
}

1;

__END__

=head1 NAME

Plack::Builder - OO and DSL to enable Plack Middlewares

=head1 SYNOPSIS

  # in .psgi
  use Plack::Builder;

  my $app = sub { ... };

  builder {
      enable "Plack::Middleware::Foo";
      enable "Plack::Middleware::Bar", opt => "val";
      enable "Plack::Middleware::Baz";
      enable sub {
          my $app = shift;
          sub {
              my $env = shift;
              $app->($env);
          };
      };
      $app;
  };

  # use URLMap

  builder {
      mount "/foo" => builder {
          enable "Plack::Middleware::Foo";
          $app;
      };

      mount "/bar" => $app2;
      mount "http://example.com/" => builder { $app3 };
  };

  # using OO interface

  my $builder = Plack::Builder->new();
  $builder->add_middleware('Foo', opt => 1);
  $app = $builder->mount('/app' => $app);
  $app = $builder->to_app($app);

=head1 DESCRIPTION

Plack::Builder gives you a quick domain specific language (DSL) to
wrap your application with Plack::Middleware subclasses. The
middleware you're trying to use should use L<Plack::Middleware> as a
base class to use this DSL, inspired by Rack::Builder.

Whenever you call C<enable> on any middleware, the middleware app is
pushed to the stack inside the builder, and then reversed when it
actually creates a wrapped application handler, so:

  builder {
      enable "Plack::Middleware::Foo";
      enable "Plack::Middleware::Bar", opt => "val";
      $app;
  };

is syntactically equal to:

  $app = Plack::Middleware::Bar->wrap($app, opt => "val");
  $app = Plack::Middleware::Foo->wrap($app);

In other words, you're supposed to C<enable> middleware from outer to inner.

=head1 INLINE MIDDLEWARE

Plack::Builder allows you to code middleware inline using a nested
code reference.

If the first argument to C<enable> is a code reference, it will be
passed an C<$app> and is supposed to return another code reference
which is PSGI application that consumes C<$env> in runtime. So:

  builder {
      enable sub {
          my $app = shift;
          sub { my $env = shift; $app->($env) };
      };
      $app;
  };

is equal to:

  my $mw = sub {
      my $app = shift;
      sub { my $env = shift; $app->($env) };
  };

  $app = $mw->($app);

=head1 URLMap support

Plack::Builder has a native support for L<Plack::App::URLMap> with C<mount> method.

  use Plack::Builder;
  my $app = builder {
      mount "/foo" => $app1;
      mount "/bar" => builder {
          enable "Plack::Middleware::Foo";
          $app2;
      };
  };

See L<Plack::App::URLMap>'s C<map> method to see what they mean. With
builder you can't use C<map> as a DSL, for the obvious reason :)

B<NOTE>: Once you use C<mount> in your builder code, you have to use
C<mount> for all the paths, including the root path (C</>). You can't
have the default app in the last line of C<builder> like:

  my $app = sub {
      my $env = shift;
      ...
  };

  builder {
      mount "/foo" => sub { ... };
      $app; # THIS DOESN'T WORK
  };

You'll get warnings saying that your mount configuration will be
ignored. Instead you should use C<< mount "/" => ... >> in the last
line to set the default fallback app.

  builder {
      mount "/foo" => sub { ... };
      mount "/" => $app;
  }

=head1 CONDITIONAL MIDDLEWARE SUPPORT

You can use C<enable_if> to conditionally enable middleware based on
the runtime environment. See L<Plack::Middleware::Conditional> for
details.

=head1 SEE ALSO

L<Plack::Middleware> L<Plack::App::URLMap> L<Plack::Middleware::Conditional>

=cut



