# vim:ft=zsh
#
# cmux ZDOTDIR bootstrap for zsh.
#
# GhosttyKit already uses a ZDOTDIR injection mechanism for zsh (setting ZDOTDIR
# to Ghostty's integration dir). cmux also needs to run its integration, but
# we must restore the user's real ZDOTDIR immediately so that:
# - /etc/zshrc sets HISTFILE relative to the real ZDOTDIR/HOME (shared history)
# - zsh loads the user's real .zprofile/.zshrc normally (no wrapper recursion)
#
# We restore ZDOTDIR from (in priority order):
# - GHOSTTY_ZSH_ZDOTDIR (set by GhosttyKit when it overwrote ZDOTDIR)
# - CMUX_ZSH_ZDOTDIR (set by cmux when it overwrote a user-provided ZDOTDIR)
# - unset (zsh treats unset ZDOTDIR as $HOME)
#
# Exec-string shells are a special case: zsh -i -c never draws a prompt, so we
# need one wrapper .zshrc pass after the user's startup files to apply Ghostty's
# deferred ssh() patch. For that case only, keep ZDOTDIR pointed at the cmux
# wrapper dir until our wrapper .zshrc runs, while sourcing the user's real rc
# files manually with the real ZDOTDIR in scope.

builtin typeset -g _cmux_real_zdotdir=""
builtin typeset -g _cmux_real_zdotdir_mode="unset"
builtin typeset -g _cmux_real_zdotfile_path=""
builtin typeset -g _cmux_wrapper_zdotdir="${ZDOTDIR-}"
builtin typeset -g _cmux_wrapper_histfile=""
builtin typeset -gi _cmux_use_exec_string_wrapper=0

if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    _cmux_real_zdotdir="$GHOSTTY_ZSH_ZDOTDIR"
    _cmux_real_zdotdir_mode="set"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${CMUX_ZSH_ZDOTDIR+X}" ]]; then
    _cmux_real_zdotdir="$CMUX_ZSH_ZDOTDIR"
    _cmux_real_zdotdir_mode="set"
    builtin unset CMUX_ZSH_ZDOTDIR
fi

if [[ -n "$_cmux_wrapper_zdotdir" ]]; then
    _cmux_wrapper_histfile="${_cmux_wrapper_zdotdir}/.zsh_history"
fi

_cmux_capture_real_zdotdir() {
    if [[ -n "${ZDOTDIR+X}" ]]; then
        _cmux_real_zdotdir="$ZDOTDIR"
        _cmux_real_zdotdir_mode="set"
    else
        _cmux_real_zdotdir=""
        _cmux_real_zdotdir_mode="unset"
    fi
}

_cmux_use_real_zdotdir() {
    if [[ "$_cmux_real_zdotdir_mode" == "set" ]]; then
        builtin export ZDOTDIR="$_cmux_real_zdotdir"
    else
        builtin unset ZDOTDIR
    fi
}

_cmux_restore_wrapper_zdotdir() {
    if [[ -n "$_cmux_wrapper_zdotdir" ]]; then
        builtin export ZDOTDIR="$_cmux_wrapper_zdotdir"
    else
        builtin unset ZDOTDIR
    fi
}

_cmux_prepare_real_zdotfile() {
    builtin local file_name="$1"

    _cmux_use_real_zdotdir
    _cmux_real_zdotfile_path="${ZDOTDIR-$HOME}/$file_name"
}

if [[ -o interactive && -n "${ZSH_EXECUTION_STRING:-}" ]]; then
    _cmux_use_exec_string_wrapper=1
    _cmux_restore_wrapper_zdotdir
else
    _cmux_use_real_zdotdir
fi

{
    _cmux_prepare_real_zdotfile ".zshenv"
    [[ ! -r "$_cmux_real_zdotfile_path" ]] || builtin source -- "$_cmux_real_zdotfile_path"

    if [[ -o interactive \
       && -z "${ZSH_EXECUTION_STRING:-}" \
       && "${CMUX_SHELL_INTEGRATION:-1}" != "0" \
       && -n "${CMUX_SHELL_INTEGRATION_DIR:-}" \
       && -r "${CMUX_SHELL_INTEGRATION_DIR}/cmux-zsh-integration.zsh" \
       && "${TERM:-}" == "xterm-256color" \
       && -z "${CMUX_ZSH_RESTORE_TERM:-}" ]]; then
        # Keep startup TERM-compatible prompt/theme selection during shell init,
        # then restore the managed xterm-256color identity before the first
        # interactive command executes.
        builtin export CMUX_ZSH_RESTORE_TERM="$TERM"
        builtin export TERM="xterm-ghostty"
        builtin typeset -g _CMUX_DELAY_TERM_RESTORE_UNTIL_FIRST_PROMPT=1
    fi
} always {
    # Preserve any user-side ZDOTDIR rebinding so the next startup file
    # resolves from the same location vanilla zsh would use.
    _cmux_capture_real_zdotdir
    (( _cmux_use_exec_string_wrapper )) && _cmux_restore_wrapper_zdotdir

    if [[ -o interactive ]]; then
        # We overwrote GhosttyKit's injected ZDOTDIR, so manually load Ghostty's
        # zsh integration if available.
        #
        # We can't rely on GHOSTTY_ZSH_ZDOTDIR here because Ghostty's own zsh
        # bootstrap unsets it before chaining into this cmux wrapper.
        if [[ "${CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION:-0}" == "1" ]]; then
            if [[ -n "${CMUX_SHELL_INTEGRATION_DIR:-}" ]]; then
                builtin typeset _cmux_ghostty="$CMUX_SHELL_INTEGRATION_DIR/ghostty-integration.zsh"
            fi
            if [[ ! -r "${_cmux_ghostty:-}" && -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
                builtin typeset _cmux_ghostty="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
            fi
            if [[ -r "$_cmux_ghostty" ]]; then
                builtin source -- "$_cmux_ghostty"
                if [[ -n "${CMUX_SHELL_INTEGRATION_DIR:-}" ]]; then
                    builtin typeset _cmux_ghostty_patch="$CMUX_SHELL_INTEGRATION_DIR/cmux-ghostty-zsh-patches.zsh"
                    [[ -r "$_cmux_ghostty_patch" ]] && builtin source -- "$_cmux_ghostty_patch"
                fi
            fi
        fi

        # Load cmux integration (unless disabled)
        if [[ "${CMUX_SHELL_INTEGRATION:-1}" != "0" && -n "${CMUX_SHELL_INTEGRATION_DIR:-}" ]]; then
            builtin typeset _cmux_integ="$CMUX_SHELL_INTEGRATION_DIR/cmux-zsh-integration.zsh"
            [[ -r "$_cmux_integ" ]] && builtin source -- "$_cmux_integ"
        fi
    fi

    if (( ! _cmux_use_exec_string_wrapper )); then
        builtin unfunction _cmux_capture_real_zdotdir _cmux_use_real_zdotdir _cmux_restore_wrapper_zdotdir _cmux_prepare_real_zdotfile 2>/dev/null
        builtin unset _cmux_real_zdotdir _cmux_real_zdotdir_mode _cmux_real_zdotfile_path _cmux_wrapper_zdotdir _cmux_wrapper_histfile _cmux_use_exec_string_wrapper
    fi

    builtin unset _cmux_ghostty _cmux_ghostty_patch _cmux_integ
}
