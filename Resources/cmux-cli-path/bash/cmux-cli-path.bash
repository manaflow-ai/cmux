# cmux-next: keep this app's bundled `cmux` first on PATH after the user's
# startup files (BundledCLIEnvironment.swift). bash in POSIX mode reads this
# file from ENV; the app saved Ghostty's ENV script in CMUX_CLI_BASH_ENV.
# Ghostty's script sources the user's startup files itself, so once it
# returns they have run and the bundled bin dir goes back to the front.
# Sourced at top level (not in a function): Ghostty's declarations stay global.
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
