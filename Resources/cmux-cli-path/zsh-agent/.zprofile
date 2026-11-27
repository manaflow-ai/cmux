# vim:ft=zsh
#
# cmux-next agent shells, login shells (see .zshenv here): runs the user's .zprofile from the user's ZDOTDIR, then moves the
# bundled `cmux` back to the front of PATH.

if (( _cmux_agent_user_set )); then
    'builtin' 'export' ZDOTDIR="$_cmux_agent_user"
else
    'builtin' 'unset' 'ZDOTDIR'
fi
_cmux_agent_file="${ZDOTDIR-$HOME}/.zprofile"
[[ ! -r "$_cmux_agent_file" ]] || 'builtin' 'source' '--' "$_cmux_agent_file"
_cmux_agent_user="${ZDOTDIR-}"
_cmux_agent_user_set=${${ZDOTDIR+1}:-0}
'builtin' 'export' ZDOTDIR="$_cmux_agent_layer"
_cmux_agent_cli_first
