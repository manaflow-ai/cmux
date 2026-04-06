# vim:ft=zsh
#
# cmux ZDOTDIR wrapper for .zprofile.
# Sources the user's real .zprofile from _CMUX_ORIG_ZDOTDIR.

builtin typeset _cmux_file="${_CMUX_ORIG_ZDOTDIR-$HOME}/.zprofile"
[[ ! -r "$_cmux_file" ]] || builtin source -- "$_cmux_file"
builtin unset _cmux_file
