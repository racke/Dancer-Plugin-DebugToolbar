package Dancer::Plugin::DebugToolbar;

=head1 NAME

Dancer::Plugin::DebugToolbar - A debugging toolbar for Dancer web applications

=cut

use strict;

use Dancer ':syntax';
use Dancer::App;
use Dancer::Plugin;
use Dancer::Route::Registry;
use File::ShareDir;
use File::Spec::Functions qw(catfile);
use Module::Loaded;
use Scalar::Util qw(blessed looks_like_number refaddr);
use Tie::Hash::Indexed;
use Time::HiRes qw(time);

our $VERSION = '0.015';

# Distribution-level shared data directory
my $dist_dir = File::ShareDir::dist_dir('Dancer-Plugin-DebugToolbar');

# Information to be displayed to the user
my $time_start;
my $dbi_trace;
my $dbi_queries;

my $route_pattern;
my $hook_registered;

my $settings = plugin_setting;

# Are we on?
if (!$settings->{enable}) {
    return 1;
}

# Default settings

if (!defined $settings->{path_prefix}) {
    # Default path prefix
    $settings->{path_prefix} = '/dancer-debug-toolbar';
}

if (!defined $settings->{show}) {
    # By default, we show data and routes
    $settings->{show} = {
        data => 1,
        routes => 1
    };
}

my $path_prefix = $settings->{path_prefix};
# Need leading slash
if ($path_prefix !~ m!^/!) {
    $path_prefix = '/' . $path_prefix;
}

if ($settings->{show}->{database}) {
    require Dancer::Plugin::DebugToolbar::DBI;
}

sub _ordered_hash (%) {
    tie my %hash => 'Tie::Hash::Indexed';
    %hash = @_;
    \%hash
}

sub _wrap_data {
    my ($var, $options, $parent_refs) = @_;
    my $ret = {};
    
    $parent_refs = {} unless defined $parent_refs;

    if (UNIVERSAL::isa($var, "ARRAY")) {
        if (!$parent_refs->{refaddr($var)}) {
            $parent_refs->{refaddr($var)} = 1;
            
            $ret->{'type'} = 'list';
            $ret->{'value'} = _ordered_hash();
            my $i = 0;
            
            # List array members
            foreach my $item (@$var) {
                $ret->{'value'}->{$i++} = _wrap_data($item, $options,
                    $parent_refs);
            }
        }
        else {
            # Cyclic reference
            $ret->{type} = 'perl/cyclic-ref';
        }
        
        $ret->{'short_value'} = 'ARRAY';
    }
    elsif (UNIVERSAL::isa($var, "HASH")) {
        if (!$parent_refs->{refaddr($var)}) {
            $parent_refs->{refaddr($var)} = 1;
            
            $ret->{'type'} = 'map';
            $ret->{'value'} = _ordered_hash();
            
            foreach my $name ($options->{sort_keys} ? sort keys %$var :
                keys %$var)
            {
                $ret->{'value'}->{$name} = _wrap_data($var->{$name}, $options,
                    $parent_refs);
            }
            
            if (my $class = blessed($var)) {
                # Blessed hash
                $ret->{'short_value'} = {
                    html => '<div class="value">' .
                        '<a href="http://search.cpan.org/perldoc?' . $class .
                        '">' . $class . '</a></div>'
                };
            }
            else {
                $ret->{'short_value'} = 'HASH';
            }
        }
        else {
            # Cyclic reference
            $ret->{type} = 'perl/cyclic-ref';
        }
    }
    elsif (looks_like_number($var)) {
        # Number
        $ret->{'type'} = 'number';
        $ret->{'value'} = $var;
    }
    elsif (defined $var) {
        # String
        $ret->{'type'} = 'string';
        $ret->{'value'} = '"' . $var . '"';
    }
    elsif (!defined $var) {
        # Undefined
        $ret->{'type'} = 'perl/undefined';
    }
    else {
        $ret->{'type'} = '';
        $ret->{'value'} = $var;
    }
    
    return $ret;
}

before sub {
    $time_start = time;
    
    if ($settings->{show}->{database}) {
        Dancer::Plugin::DebugToolbar::DBI::reset();
    }
};

my $after_hook = sub {
    my $response = shift;
    my $content = $response->content;
    my $status = $response->status;
    
    return if $status < 200 || $status == 204 || $status == 304;
    return if $response->content_type !~ m!^(?:text/html|application/xhtml\+xml)!;
    
	my $time_elapsed = time - $time_start;
    
    #
    # Get routes
    #
    my $routes = Dancer::App->current->registry->routes();
    
    my $all_routes = {};
    my $matching_routes = {};
    
    foreach my $type (keys %$routes) {
        $all_routes->{uc $type} = [];
        $matching_routes->{uc $type} = [];
        
        foreach my $route (@{$routes->{$type}}) {
            # Exclude our own route used to access the toolbar JS/CSS files
            next if ($route->{'pattern'} eq $route_pattern);
            
            my $route_info = {};
            my $route_data = _ordered_hash(
                'Pattern' => $route->{'pattern'},
                'Compiled regexp' => $route->{'_compiled_regexp'}
            );
            
            # Is this a matching route?
            if (request->path_info =~ $route->{'_compiled_regexp'}) {
                $route_data->{'Match data'} = $route->match_data;
            }
            
            $route_info = {
                'pattern' => $route->{'pattern'},
                'matching' => defined $route_data->{'Match data'},
                'data' => _wrap_data($route_data)
            };

            # Add the route to the list of all routes
            push(@{$all_routes->{uc $type}}, $route_info);

            if ($route_info->{matching}) {
                # Add the route to the list of matching routes
                push(@{$matching_routes->{uc $type}}, $route_info);
            }
        }
    }
    
    my $config = config;
    my $request = request;
    my $session;
    my $vars = vars;
    
    # Session must be defined in the configuration, otherwise it doesn't exist
    if (config->{'session'}) {
        $session = session;
    }
    
    # Remove private members from request object
    for my $name (keys %$request) {
        delete $request->{$name} if ($name =~ /^_/);
    }

    my $show = $settings->{'show'};
    
    if ($show->{'database'}) {
        # Get the collected DBI trace and queries    
        $dbi_trace = Dancer::Plugin::DebugToolbar::DBI::get_dbi_trace();
        $dbi_queries = Dancer::Plugin::DebugToolbar::DBI::get_dbi_queries();
    }
    
    my $toolbar_cfg = {
        'toolbar' => {
            'logo' => 1,
            'buttons' => _ordered_hash(
                'time' => {
                    'text' => sprintf("%.04fs", $time_elapsed)
                },
                'data' => $show->{'data'} ? {
                    'text' => 'data'
                } : undef,
                'routes' => $show->{'routes'} ? {
                    'text' => 'routes'  
                } : undef,
                'database' => $show->{'database'} ? {
                    'text' => 'database'
                } : undef,
                'align' => 1,
                'close' => 1
            )
        },
        'screens' => {
            'data' => {
                'title' => 'Data',
                'pages' => _ordered_hash(
                    'config' => {
                        'name' => 'config',
                        'type' => 'data-structure/perl',
                        'data' => _wrap_data($config, { sort_keys => 1 })
                    },
                    'request' => {
                        'name' => 'request',
                        'type' => 'data-structure/perl',
                        'data' => _wrap_data($request, { sort_keys => 1 })
                    },
                    'session' => $session ? {
                        'name' => 'session',
                        'type' => 'data-structure/perl',
                        'data' => _wrap_data($session, { sort_keys => 1 })
                    } : 1,
                    'vars' => {
                        'name' => 'vars',
                        'type' => 'data-structure/perl',
                        'data' => _wrap_data($vars, { sort_keys => 1 })
                    }
                )
            },
            'routes' => {
                'title' => 'Routes',
                'pages' => _ordered_hash(
                    'all' => {
                        'type' => 'routes',
                        'routes' => $all_routes
                    },
                    'matching' => {
                        'type' => 'routes',
                        'routes' => $matching_routes
                    }
                )
            },
            # Database
            'database' => $show->{'database'} ? {
                'title' => 'Database',
                'pages' => _ordered_hash(
                    'trace' => {
                        'type' => 'text',
                        'content' => $dbi_trace
                    },
                    'queries' => {
                        'type' => 'database-queries',
                        'queries' => $dbi_queries
                    }
                )
            } : undef
        }
    };
    
    my $html;
    open(F, "<", catfile($dist_dir, 'debugtoolbar', 'html',
        'debugtoolbar.html'));
    {
        local $/;
        $html = <F>;
    }
    close(F);
    
    # Encode the configuration as JSON
    my $cfg_json = to_json($toolbar_cfg);
    
    # Do some replacements so that the JSON data can be made into a JS string
    # wrapped in single quotes
    $cfg_json =~ s!\\!\\\\!gm;
    $cfg_json =~ s!\n!\\\n!gm;
    $cfg_json =~ s!'!\\'!gm;

    $html =~ s/%DEBUGTOOLBAR_CFG%/$cfg_json/m;
    
    my $uri_base = request->uri_base . $path_prefix;
    $html =~ s/%BASE%/$uri_base/mg;
    
    $content =~ s!(?=</body>\s*</html>\s*$)!$html!msi;
    
    $response->content($content);
};

after sub {
    # Try to get the $after_hook sub executed as the very last hook (after all
    # the other hooks defined in the application)
    return if $hook_registered;
    after $after_hook;
    $hook_registered = 1;
};

$route_pattern = qr(^$path_prefix/.*);
    
get $route_pattern => sub {
    (my $path = request->path_info) =~ s!^$path_prefix/!!;
    
    send_file(catfile($dist_dir, 'debugtoolbar', split(m!/!, $path)),
        system_path => 1);
};

register_plugin;

1; # End of Dancer::Plugin::DebugToolbar
__END__

=pod

=head1 VERSION

Version 0.015

=head1 SYNOPSIS

Add the plugin to your web application:

    use Dancer::Plugin::DebugToolbar;
    
And enable it in the configuration file, preferably in the development
environment (C<environments/development.yml>):

    plugins:
        DebugToolbar:
            enable: 1


=head1 DESCRIPTION

Dancer::Plugin::DebugToolbar allows you to add a debugging toolbar to your
Dancer web application.

=head1 CONFIGURATION

To enable and configure the plugin, add its settings to the Dancer configuration
file, under C<plugins>:

    plugins:
        DebugToolbar:
            enable: 1
            ...

You can do this either in the main configuration file
(C<config.yml>), or in the configuration file for a specific environment (under
C<environments/>). Normally, you'll want to enable the toolbar for the
development enviroment (C<environments/development.yml>).

The available configuration settings are described below.

=head2 enable

This setting enables the debugging toolbar.

Example:

    enable: 1
    
=head2 show

The C<show> setting lets you choose which information will be provided by the
debugging toolbar.

Example:

    show:
        database: 1
        routes: 1

The available options are:

=over

=item * data

Data inspection screen. Allows you to inspect the C<config>, C<request>,
C<session>, and C<vars> data structures.

=item * database

Database information screen. Shows L<DBI> trace and queries log.

=item * routes

Routes screen. Shows all the routes defined in the application, and indicates
the matching routes.

=back


If the C<show> setting is not defined, the C<data> and C<routes> screens are
displayed by default.

=head2 path_prefix

The C<path_prefix> setting allows you to change the URL path prefix that the
toolbar uses to access its resources (e.g., CSS and JavaScript files). By
default, it's set to C</dancer-debug-toolbar>.

Example:

    path_prefix: /toolbar-files

=head1 AUTHOR

Michal Wojciechowski, C<< <odyniec at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-dancer-plugin-debugtoolbar at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Dancer-Plugin-DebugToolbar>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Dancer::Plugin::DebugToolbar


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Dancer-Plugin-DebugToolbar>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Dancer-Plugin-DebugToolbar>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Dancer-Plugin-DebugToolbar>

=item * Search CPAN

L<http://search.cpan.org/dist/Dancer-Plugin-DebugToolbar/>

=back


=head1 LICENSE AND COPYRIGHT

Copyright 2011 Michal Wojciechowski.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut
