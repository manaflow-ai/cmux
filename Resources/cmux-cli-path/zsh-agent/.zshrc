# vim:ft=zsh
#
# cmux-next agent shells, interactive shells (see .zshenv here): /etc/zshrc
# ran with ZDOTDIR on this directory, so a HISTFILE it put here goes back to
# the user's directory. Then runs the user's .zshrc from the user's ZDOTDIR
# and moves the bundled `cmux` back to the front of PATH. A non-login shell
# reads no startup file after this one and restores the user's ZDOTDIR here.

if (( _cmux_agent_user_set )); then
    'builtin' 'export' ZDOTDIR="$_cmux_agent_user"
else
    'builtin' 'unset' 'ZDOTDIR'
fi
if [[ "${HISTFILE-}" == "$_cmux_agent_layer"/* ]]; then
    HISTFILE="${ZDOTDIR-$HOME}/${HISTFILE:t}"
fi
_cmux_agent_file="${ZDOTDIR-$HOME}/.zshrc"
[[ ! -r "$_cmux_agent_file" ]] || 'builtin' 'source' '--' "$_cmux_agent_file"
_cmux_agent_user="${ZDOTDIR-}"
_cmux_agent_user_set=${${ZDOTDIR+1}:-0}
_cmux_agent_cli_first
if [[ -o 'login' ]]; then
    'builtin' 'export' ZDOTDIR="$_cmux_agent_layer"
else
    _cmux_agent_finish_interactive
fi
