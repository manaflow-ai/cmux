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
}
