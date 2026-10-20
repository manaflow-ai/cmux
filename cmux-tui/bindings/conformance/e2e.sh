#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGS=("$@")
if [[ -n "${CMUX_TUI_BIN:-}" ]]; then
  ARGS+=(--cmux-tui-bin "$CMUX_TUI_BIN")
fi
exec python3 "$SCRIPT_DIR/runner.py" "${ARGS[@]}"
