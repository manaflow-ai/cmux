# cmux-next: keep this app's bundled `cmux` first on PATH after the user's
# startup files (BundledCLIEnvironment.swift). bash in POSIX mode reads this
# file from ENV; the app saved Ghostty's ENV script in CMUX_CLI_BASH_ENV.
# Ghostty's script sources the user's startup files itself, so once it
# returns they have run and the bundled bin dir goes back to the front.
# Sourced at top level (not in a function): Ghostty's declarations stay global.
# A terminal started with saved output (the classic session import) names its
# replay file in CMUX_RESTORE_SCROLLBACK_FILE; it prints once after the startup
# files, above the first prompt, and goes. Only a file in the app's private
# cmux-next-scrollback folder is printed or removed.
__cmux_replay_file="${CMUX_RESTORE_SCROLLBACK_FILE-}"
builtin unset CMUX_RESTORE_SCROLLBACK_FILE
if [ -n "${CMUX_CLI_BASH_ENV-}" ]; then
  __cmux_cli_next_env="$CMUX_CLI_BASH_ENV"
  builtin unset CMUX_CLI_BASH_ENV
  [ -r "$__cmux_cli_next_env" ] && builtin source "$__cmux_cli_next_env"
  builtin unset __cmux_cli_next_env
fi
if [[ "$-" == *i* && -n "${CMUX_BUNDLED_CLI_PATH-}" && -x "${CMUX_BUNDLED_CLI_PATH}" ]]; then
  __cmux_cli_dir="${CMUX_BUNDLED_CLI_PATH%/*}"
  __cmux_cli_rest=":${PATH}:"
  while [[ "$__cmux_cli_rest" == *":${__cmux_cli_dir}:"* ]]; do
    __cmux_cli_rest="${__cmux_cli_rest//:"${__cmux_cli_dir}":/:}"
  done
  __cmux_cli_rest="${__cmux_cli_rest#:}"
  __cmux_cli_rest="${__cmux_cli_rest%:}"
  PATH="${__cmux_cli_dir}${__cmux_cli_rest:+:${__cmux_cli_rest}}"
  builtin hash -r
  builtin unset __cmux_cli_dir __cmux_cli_rest
fi
if [[ "$-" == *i* && "${__cmux_replay_file%/*}" == */cmux-next-scrollback && -f "$__cmux_replay_file" ]]; then
  /bin/cat -- "$__cmux_replay_file" 2>/dev/null
  /bin/rm -f -- "$__cmux_replay_file" 2>/dev/null
fi
builtin unset __cmux_replay_file
