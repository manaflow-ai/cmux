# vim:ft=zsh
#
# cmux-next: keep this app's bundled `cmux` first on PATH after the user's
# startup files (BundledCLIEnvironment.swift). The app sets ZDOTDIR to this
# directory and saves the ZDOTDIR it replaced (Ghostty's integration dir or
# the user's) in CMUX_CLI_ZSH_ZDOTDIR. zsh reads only this .zshenv from here:
# it restores that ZDOTDIR first, so every later startup file (and /etc/zshrc's
# HISTFILE) comes from the right place, then sources the next .zshenv, which
# continues the chain (Ghostty's restores the user's ZDOTDIR and loads its
# integration).
#
# The user's .zprofile, .zshrc and .zlogin run after this file and may prepend
# directories that hold another `cmux`, so a one-shot precmd hook moves the
# bundled bin dir back to the front before the first prompt.
#
# A terminal started with saved output (the classic session import) names its
# replay file in CMUX_RESTORE_SCROLLBACK_FILE: another one-shot precmd hook
# prints it once above the first prompt and removes it. Only a file in the
# app's private cmux-next-scrollback folder is printed or removed.

if [[ -n "${CMUX_RESTORE_SCROLLBACK_FILE-}" ]]; then
    'builtin' 'typeset' -g _cmux_replay_file="$CMUX_RESTORE_SCROLLBACK_FILE"
    'builtin' 'unset' 'CMUX_RESTORE_SCROLLBACK_FILE'
fi

if [[ -n "${CMUX_CLI_ZSH_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$CMUX_CLI_ZSH_ZDOTDIR"
    'builtin' 'unset' 'CMUX_CLI_ZSH_ZDOTDIR'
else
    'builtin' 'unset' 'ZDOTDIR'
fi

{
    'builtin' 'typeset' _cmux_cli_file=${ZDOTDIR-$HOME}"/.zshenv"
    [[ ! -r "$_cmux_cli_file" ]] || 'builtin' 'source' '--' "$_cmux_cli_file"
} always {
    'builtin' 'unset' '_cmux_cli_file'
    if [[ -o 'interactive' && -n "${CMUX_BUNDLED_CLI_PATH-}" ]]; then
        _cmux_cli_path_first() {
            'builtin' 'local' cli="${CMUX_BUNDLED_CLI_PATH-}"
            if [[ -n "$cli" && -x "$cli" ]]; then
                'builtin' 'local' dir="${cli:h}"
                path=("$dir" "${(@)path:#${(b)dir}}")
            fi
            precmd_functions=("${(@)precmd_functions:#_cmux_cli_path_first}")
            'builtin' 'unfunction' '_cmux_cli_path_first'
        }
        'builtin' 'typeset' -ag precmd_functions
        precmd_functions=(_cmux_cli_path_first "${(@)precmd_functions}")
    fi
    # cmux-tui's agent shim directory (`codex` and `claude` that add this
    # terminal's hooks) goes back to the front before each command line:
    # startup files and prompt hooks often prepend the directory of the real
    # agent, and Codex runs its hooks in a shared daemon that cannot see this
    # terminal's environment, so only the shim can route them. The daemon's
    # own integration (cmux-tui shell_integration/agent-shims.zsh) carries the
    # same functions; registering twice leaves one hook.
    if [[ -o 'interactive' && -n "${CMUX_TUI_AGENT_SHIMS-}" ]]; then
        _cmux_tui_agent_shims_first() {
            'builtin' 'local' '-i' ret=$?
            'builtin' 'emulate' '-L' 'zsh' '-o' 'no_warn_create_global' '-o' 'no_aliases'
            'builtin' 'local' dir=${CMUX_TUI_AGENT_SHIMS-}
            if [[ -n $dir && -d $dir && ${path[1]-} != "$dir" ]]; then
                path=("$dir" "${(@)path:#${~${(b)dir}}}")
            fi
            'builtin' 'return' ret
        }
        # Registered from the first precmd, after .zshrc: a framework that
        # resets preexec_functions there would otherwise drop the hook.
        _cmux_tui_agent_shims_install() {
            'builtin' 'local' '-i' ret=$?
            'builtin' 'emulate' '-L' 'zsh' '-o' 'no_warn_create_global' '-o' 'no_aliases'
            'builtin' 'typeset' -ag precmd_functions preexec_functions
            precmd_functions=("${(@)precmd_functions:#_cmux_tui_agent_shims_install}")
            preexec_functions=("${(@)preexec_functions:#_cmux_tui_agent_shims_first}" _cmux_tui_agent_shims_first)
            'builtin' 'unfunction' '_cmux_tui_agent_shims_install'
            'builtin' 'return' ret
        }
        'builtin' 'typeset' -ag precmd_functions
        precmd_functions+=(_cmux_tui_agent_shims_install)
    fi
    # A terminal of an incognito workspace (CMUX_TUI_INCOGNITO, set by the
    # daemon) keeps no history: startup files set HISTFILE again (macOS
    # /etc/zshrc does), so each prompt unsets it and SAVEHIST, and each line
    # stays in memory only. The daemon's own integration (cmux-tui
    # shell_integration/incognito-history.zsh) carries the same functions;
    # registering twice leaves one hook.
    if [[ -o 'interactive' && -n "${CMUX_TUI_INCOGNITO-}" ]]; then
        _cmux_tui_incognito_history() {
            'builtin' 'unset' 'HISTFILE'
            'builtin' 'typeset' -g SAVEHIST=0
        }
        _cmux_tui_incognito_addhistory() {
            _cmux_tui_incognito_history
            'builtin' 'return' 2
        }
        'builtin' 'typeset' -ag precmd_functions zshaddhistory_functions
        precmd_functions=("${(@)precmd_functions:#_cmux_tui_incognito_history}" _cmux_tui_incognito_history)
        zshaddhistory_functions=("${(@)zshaddhistory_functions:#_cmux_tui_incognito_addhistory}" _cmux_tui_incognito_addhistory)
    fi
    if [[ -o 'interactive' && -n "${_cmux_replay_file-}" ]]; then
        _cmux_replay_first() {
            'builtin' 'local' file="${_cmux_replay_file-}"
            'builtin' 'unset' '_cmux_replay_file'
            if [[ "${file:h:t}" == 'cmux-next-scrollback' && -f "$file" ]]; then
                /bin/cat -- "$file" 2>/dev/null
                /bin/rm -f -- "$file" 2>/dev/null
            fi
            precmd_functions=("${(@)precmd_functions:#_cmux_replay_first}")
            'builtin' 'unfunction' '_cmux_replay_first'
        }
        'builtin' 'typeset' -ag precmd_functions
        precmd_functions=(_cmux_replay_first "${(@)precmd_functions}")
    else
        'builtin' 'unset' '_cmux_replay_file'
    fi
}
