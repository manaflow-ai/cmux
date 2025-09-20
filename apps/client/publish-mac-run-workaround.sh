#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_BIN() {
  local bin_path="$1"
  local search="$2"
  local replacement="$3"
  if [ -f "$bin_path" ] && [ ! -L "$bin_path" ]; then
    if grep -q "$search" "$bin_path"; then
      echo "Patching $(basename "$bin_path") binary for publish build (copied node_modules)..."
      local tmp_file="$(mktemp)"
      python3 - "$bin_path" "$search" "$replacement" "$tmp_file" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
needle = sys.argv[2]
replacement = sys.argv[3]
text = path.read_text()
pathlib.Path(sys.argv[4]).write_text(text.replace(needle, replacement))
PY
      mv "$tmp_file" "$bin_path"
      chmod +x "$bin_path"
    fi
  fi
}

PATCH_BIN "$SCRIPT_DIR/node_modules/.bin/electron-vite" "../dist/cli.js" "../electron-vite/dist/cli.js"
PATCH_BIN "$SCRIPT_DIR/node_modules/.bin/electron-builder" "./out/cli/cli" "../electron-builder/out/cli/cli"

exec "$SCRIPT_DIR/build-mac-workaround.sh" "$@"
