#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$#" -eq 0 ]]; then
  exec python3 "$SCRIPT_DIR/codegen/generate.py" --write
fi

exec python3 "$SCRIPT_DIR/codegen/generate.py" "$@"
