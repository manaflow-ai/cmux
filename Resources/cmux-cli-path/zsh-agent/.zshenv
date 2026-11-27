# vim:ft=zsh
#
# cmux-next agent shells: keep this app's bundled `cmux` first on PATH in the
# shells an agent starts for its commands (Codex and Claude Code run each one
# in a fresh `zsh -lc` or `zsh -c`). Those shells read the user's .zshenv,
# .zprofile and .zlogin again, which often prepend ~/.local/bin, where an old
# PyPI `cmux` can live; the agent then runs a `cmux` without this app's verbs.
#
# acpmux starts every agent with ZDOTDIR set to this directory and the user's
# ZDOTDIR (when set) in CMUX_CLI_AGENT_ZDOTDIR (login_env.rs,
# `agent_shell_env`). Each startup file here sources the user's file of the
# same name from the user's ZDOTDIR (or HOME), at top level so its variables
# stay global, then moves the bundled bin dir back to the front.
#
# ZDOTDIR stays on this directory until the last startup file zsh reads,
# which restores the user's ZDOTDIR for the command or the prompt: .zlogin
# for login shells, .zshrc for other interactive shells, and this file for
# non-interactive non-login shells. .zshrc here also moves the HISTFILE that
# /etc/zshrc derived from this directory back to the user's. Interactive
# shells (`zsh -ic` runs no prompt, so the files fix PATH themselves) also
# move the CLI first once more at the first prompt, after prompt hooks that
# prepend directories.
#
# A user .zshenv may set its own ZDOTDIR (an XDG setup): later files then
# come from that directory. Without CMUX_BUNDLED_CLI_PATH the layer only runs
# the user's files.

'builtin' 'typeset' -g _cmux_agent_layer="${ZDOTDIR-}"
if [[ -n "${CMUX_CLI_AGENT_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$CMUX_CLI_AGENT_ZDOTDIR"
else
    'builtin' 'unset' 'ZDOTDIR'
fi

_cmux_agent_cli_first() {
    'builtin' 'local' cli="${CMUX_BUNDLED_CLI_PATH-}"
    if [[ -n "$cli" && -x "$cli" ]]; then
        'builtin' 'local' dir="${cli:h}"
        path=("$dir" "${(@)path:#${(b)dir}}")
    fi
}

# Restores the user's ZDOTDIR (as the last user file left it) and removes
# everything this layer defined; `keep_hook` keeps the interactive hook.
_cmux_agent_finish() {
    if (( _cmux_agent_user_set )); then
        'builtin' 'export' ZDOTDIR="$_cmux_agent_user"
    else
        'builtin' 'unset' 'ZDOTDIR'
    fi
    'builtin' 'unset' '_cmux_agent_layer' '_cmux_agent_user' '_cmux_agent_user_set' \
        '_cmux_agent_file' 'CMUX_CLI_AGENT_ZDOTDIR'
    [[ "${1-}" == 'keep_hook' ]] || 'builtin' 'unfunction' '_cmux_agent_cli_first'
    'builtin' 'unfunction' '_cmux_agent_finish'
}

'builtin' 'typeset' -g _cmux_agent_file="${ZDOTDIR-$HOME}/.zshenv"
[[ ! -r "$_cmux_agent_file" ]] || 'builtin' 'source' '--' "$_cmux_agent_file"
'builtin' 'typeset' -g _cmux_agent_user="${ZDOTDIR-}"
'builtin' 'typeset' -gi _cmux_agent_user_set=${${ZDOTDIR+1}:-0}
_cmux_agent_cli_first

# The last file of an interactive shell ends with this: finish, and move the
# CLI first once more at the first prompt.
_cmux_agent_finish_interactive() {
    _cmux_agent_finish keep_hook
    'builtin' 'unfunction' '_cmux_agent_finish_interactive'
    _cmux_agent_cli_first_once() {
        _cmux_agent_cli_first
        precmd_functions=("${(@)precmd_functions:#_cmux_agent_cli_first_once}")
        'builtin' 'unfunction' '_cmux_agent_cli_first_once' '_cmux_agent_cli_first'
    }
    'builtin' 'typeset' -ag precmd_functions
    precmd_functions=(_cmux_agent_cli_first_once "${(@)precmd_functions}")
}

if [[ -o 'interactive' || -o 'login' ]]; then
    'builtin' 'export' ZDOTDIR="$_cmux_agent_layer"
else
    'builtin' 'unfunction' '_cmux_agent_finish_interactive'
    _cmux_agent_finish
fi
