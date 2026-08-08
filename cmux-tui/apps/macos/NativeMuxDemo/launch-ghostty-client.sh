#!/usr/bin/env bash

set -euo pipefail

if (( $# < 4 )); then
  echo "Usage: launch-ghostty-client.sh <Ghostty.app> <cmux-tui> <ghostty args...> -- <cmux-tui args...>" >&2
  exit 2
fi

GHOSTTY_APP="$1"
CMUX_TUI="$2"
shift 2

GHOSTTY_ARGUMENTS=()
while [[ $# -gt 0 && "$1" != "--" ]]; do
  GHOSTTY_ARGUMENTS+=("$1")
  shift
done
if [[ $# -eq 0 ]]; then
  echo "Ghostty arguments must be followed by -- and cmux-tui arguments." >&2
  exit 2
fi
shift

GHOSTTY_EXECUTABLE="$GHOSTTY_APP/Contents/MacOS/ghostty"
if [[ ! -x "$GHOSTTY_EXECUTABLE" ]]; then
  echo "Ghostty executable is missing: $GHOSTTY_EXECUTABLE" >&2
  exit 1
fi
if [[ ! -x "$CMUX_TUI" ]]; then
  echo "cmux-tui executable is missing: $CMUX_TUI" >&2
  exit 1
fi

CMUX_TUI_DIRECTORY="$(cd "$(dirname "$CMUX_TUI")" && pwd -P)"
CMUX_TUI_NAME="$(basename "$CMUX_TUI")"

# Ghostty's macOS PTY launcher accepts a command name through `login`, but an
# absolute executable path exits before the PTY command starts. Prepending the
# exact build directory keeps command lookup deterministic. The CLI launch
# source also makes this process create its own first window when another
# Ghostty instance is already running.
export PATH="$CMUX_TUI_DIRECTORY:$PATH"
export GHOSTTY_MAC_LAUNCH_SOURCE=cli
exec "$GHOSTTY_EXECUTABLE" "${GHOSTTY_ARGUMENTS[@]}" -e "$CMUX_TUI_NAME" "$@"
