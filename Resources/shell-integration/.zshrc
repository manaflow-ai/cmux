# vim:ft=zsh
#
# cmux ZDOTDIR wrapper for .zshrc.
# Sources the user's real .zshrc, then loads Ghostty and cmux shell
# integration.  Loading integration HERE (after .zshrc) ensures it runs
# after tools like Kiro CLI / Amazon Q that may reset precmd_functions
# in .zprofile or .zshrc.

# Source the user's real .zshrc.
builtin typeset _cmux_file="${_CMUX_ORIG_ZDOTDIR-$HOME}/.zshrc"
[[ ! -r "$_cmux_file" ]] || builtin source -- "$_cmux_file"
builtin unset _cmux_file

# Fix HISTFILE: /etc/zshrc sets HISTFILE based on ZDOTDIR which currently
# points to our integration dir.  Only fix if it still points there;
# if the user's .zshrc set a custom HISTFILE, respect it.
if [[ "$HISTFILE" == "${ZDOTDIR}"/* ]]; then
    HISTFILE="${_CMUX_ORIG_ZDOTDIR-$HOME}/.zsh_history"
fi

# Load Ghostty shell integration (if requested by cmux).
if [[ "${CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION:-0}" == "1" ]]; then
    if [[ -n "${CMUX_SHELL_INTEGRATION_DIR:-}" ]]; then
        builtin typeset _cmux_ghostty="$CMUX_SHELL_INTEGRATION_DIR/ghostty-integration.zsh"
    fi
    if [[ ! -r "${_cmux_ghostty:-}" && -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
        builtin typeset _cmux_ghostty="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
    fi
    [[ -r "$_cmux_ghostty" ]] && builtin source -- "$_cmux_ghostty"
fi

# Load cmux shell integration.
if [[ "${CMUX_SHELL_INTEGRATION:-1}" != "0" && -n "${CMUX_SHELL_INTEGRATION_DIR:-}" ]]; then
    builtin typeset _cmux_integ="$CMUX_SHELL_INTEGRATION_DIR/cmux-zsh-integration.zsh"
    [[ -r "$_cmux_integ" ]] && builtin source -- "$_cmux_integ"
fi

# Restore the user's original ZDOTDIR now that all startup files are done.
if [[ "${_CMUX_ORIG_ZDOTDIR}" == "${HOME}" ]]; then
    builtin unset ZDOTDIR
else
    builtin export ZDOTDIR="${_CMUX_ORIG_ZDOTDIR}"
fi
builtin unset _CMUX_ORIG_ZDOTDIR _cmux_ghostty _cmux_integ
