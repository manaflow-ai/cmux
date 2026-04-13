# vim:ft=zsh
#
# Exec-string wrapper for zsh interactive shells. This runs after the user's
# .zshrc so zsh -i -c gets the same post-startup ssh() patching that prompted
# shells receive from Ghostty's deferred init.

if (( $+functions[_cmux_prepare_real_zdotfile] )); then
    {
        _cmux_prepare_real_zdotfile ".zshrc"
        [[ ! -r "$_cmux_real_zdotfile_path" ]] || builtin source -- "$_cmux_real_zdotfile_path"
    } always {
        _cmux_capture_real_zdotdir
    }
fi

if (( $+functions[_cmux_use_real_zdotdir] )); then
    _cmux_use_real_zdotdir
fi

# /etc/zshrc used the wrapper ZDOTDIR for exec-string shells. Repair only the
# wrapper-derived default; preserve any HISTFILE the user chose explicitly.
if [[ -n "${_cmux_wrapper_histfile:-}" && "${HISTFILE-}" == "$_cmux_wrapper_histfile" ]]; then
    HISTFILE="${ZDOTDIR-$HOME}/.zsh_history"
fi

if (( $+functions[_cmux_patch_ghostty_ssh] )); then
    _cmux_patch_ghostty_ssh
fi

builtin unfunction _cmux_capture_real_zdotdir _cmux_use_real_zdotdir _cmux_restore_wrapper_zdotdir _cmux_prepare_real_zdotfile 2>/dev/null
builtin unset _cmux_real_zdotdir _cmux_real_zdotdir_mode _cmux_real_zdotfile_path _cmux_wrapper_zdotdir _cmux_wrapper_histfile _cmux_use_exec_string_wrapper
