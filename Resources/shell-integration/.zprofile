# vim:ft=zsh
#
# Exec-string wrapper for zsh login shells. cmux keeps ZDOTDIR pointed at this
# wrapper directory until .zshrc so zsh -i -c can install Ghostty's deferred
# ssh() patch after the user's startup files run.

if (( $+functions[_cmux_prepare_real_zdotfile] )); then
    {
        _cmux_prepare_real_zdotfile ".zprofile"
        [[ ! -r "$_cmux_real_zdotfile_path" ]] || builtin source -- "$_cmux_real_zdotfile_path"
    } always {
        _cmux_capture_real_zdotdir
        _cmux_restore_wrapper_zdotdir
    }
fi
