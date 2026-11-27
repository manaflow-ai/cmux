# vim:ft=zsh
#
# cmux-next agent shells, login shells (see .zshenv here): runs the user's .zlogin from the user's ZDOTDIR, moves the bundled
# `cmux` back to the front of PATH, and restores the user's ZDOTDIR for the
# command. zsh reads no startup file after this one.

if (( _cmux_agent_user_set )); then
    'builtin' 'export' ZDOTDIR="$_cmux_agent_user"
else
    'builtin' 'unset' 'ZDOTDIR'
fi
_cmux_agent_file="${ZDOTDIR-$HOME}/.zlogin"
[[ ! -r "$_cmux_agent_file" ]] || 'builtin' 'source' '--' "$_cmux_agent_file"
_cmux_agent_user="${ZDOTDIR-}"
_cmux_agent_user_set=${${ZDOTDIR+1}:-0}
_cmux_agent_cli_first
if [[ -o 'interactive' ]]; then
    _cmux_agent_finish_interactive
else
    'builtin' 'unfunction' '_cmux_agent_finish_interactive'
    _cmux_agent_finish
fi
