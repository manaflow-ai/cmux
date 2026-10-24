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
# cmux-tui's agent shim directory (`codex` and `claude` that add this
# terminal's hooks) goes back to the front now and at each prompt: startup
# files and prompt hooks often prepend the directory of the real agent, and
# Codex runs its hooks in a shared daemon that cannot see this terminal's
# environment, so only the shim can route them. The daemon's own integration
# (cmux-tui shell_integration/agent-shims.bash) carries the same block;
# whichever runs first registers the hook. Not a bash-preexec preexec hook: a
# non-zero return there (the previous status, kept for the prompt) skips the
# command under extdebug. A nested shell can inherit PROMPT_COMMAND without
# the function, hence the redirection.
if [[ "$-" == *i* && -n "${CMUX_TUI_AGENT_SHIMS-}" && -z "${_cmux_tui_agent_shims_registered-}" ]]; then
  _cmux_tui_agent_shims_registered=1
  _cmux_tui_agent_shims_first() {
    builtin local ret=$? dir="${CMUX_TUI_AGENT_SHIMS-}"
    if [[ -n "$dir" && -d "$dir" && "$PATH" != "$dir" && "$PATH" != "$dir:"* ]]; then
      builtin local rest=":$PATH:"
      while [[ "$rest" == *":$dir:"* ]]; do
        rest="${rest/":$dir:"/:}"
      done
      rest="${rest#:}"
      rest="${rest%:}"
      PATH="$dir${rest:+:$rest}"
    fi
    builtin return "$ret"
  }
  _cmux_tui_agent_shims_first || builtin true
  # bash runs the entries of an array PROMPT_COMMAND from 5.1 on (before, only
  # its first element, which the string branch extends); `@a` reads the type
  # without the fork of `$(declare -p)`.
  if [[ -n "${bash_preexec_imported-}${__bp_imported-}" ]]; then
    precmd_functions+=(_cmux_tui_agent_shims_first)
  elif (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )) \
    && [[ ${PROMPT_COMMAND@a} == *a* ]]; then
    PROMPT_COMMAND+=("_cmux_tui_agent_shims_first 2>/dev/null")
  elif [[ -z "${PROMPT_COMMAND-}" ]]; then
    PROMPT_COMMAND="_cmux_tui_agent_shims_first 2>/dev/null"
  else
    [[ "${PROMPT_COMMAND}" =~ (\;[[:space:]]*|$'\n')$ ]] || PROMPT_COMMAND+=";"
    PROMPT_COMMAND+="_cmux_tui_agent_shims_first 2>/dev/null"
  fi
fi
if [[ "$-" == *i* && "${__cmux_replay_file%/*}" == */cmux-next-scrollback && -f "$__cmux_replay_file" ]]; then
  /bin/cat -- "$__cmux_replay_file" 2>/dev/null
  /bin/rm -f -- "$__cmux_replay_file" 2>/dev/null
fi
builtin unset __cmux_replay_file
