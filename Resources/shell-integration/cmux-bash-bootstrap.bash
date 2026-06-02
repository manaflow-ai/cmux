# cmux bash prompt bootstrap.
#
# macOS ships /bin/bash 3.2, where Ghostty's automatic bash integration is
# unsupported and HOME-based wrapper startup is not reliable. cmux instead
# exports the contents of this file as PROMPT_COMMAND so it runs once on the
# first interactive prompt: it sources cmux's bash integration and then hands
# control to _cmux_prompt_command.
#
# This file is the single source of truth. Sources/GhosttyTerminalView.swift
# reads it and exports it verbatim as PROMPT_COMMAND, and
# tests/test_issue_5164_starship_prompt_composition.py exercises it.
unset PROMPT_COMMAND
if [[ "${CMUX_LOAD_GHOSTTY_BASH_INTEGRATION:-0}" == "1" && -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
    _cmux_ghostty_bash="$GHOSTTY_RESOURCES_DIR/shell-integration/bash/ghostty.bash"
    [[ -r "$_cmux_ghostty_bash" ]] && source "$_cmux_ghostty_bash"
fi
if [[ "${CMUX_SHELL_INTEGRATION:-1}" != "0" && -n "${CMUX_SHELL_INTEGRATION_DIR:-}" ]]; then
    _cmux_bash_integration="$CMUX_SHELL_INTEGRATION_DIR/cmux-bash-integration.bash"
    [[ -r "$_cmux_bash_integration" ]] && source "$_cmux_bash_integration"
fi
unset _cmux_ghostty_bash _cmux_bash_integration
if declare -F _cmux_prompt_command >/dev/null 2>&1; then _cmux_prompt_command; fi
