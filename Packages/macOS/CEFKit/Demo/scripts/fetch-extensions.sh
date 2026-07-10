#!/bin/zsh
# Optional: stage real Chrome extensions (uBlock Origin etc.) for manual demo
# runs. Point CEFKIT_EXTENSIONS_SOURCE at a directory of unpacked extensions;
# each subdirectory containing a manifest.json is copied into Demo/Extensions
# (gitignored) and bundled by copy-cef-runtime.sh on the next build.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${CEFKIT_EXTENSIONS_SOURCE:-}"

if [[ -z "$SOURCE" || ! -d "$SOURCE" ]]; then
  echo "Set CEFKIT_EXTENSIONS_SOURCE to a directory of unpacked extensions." >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/Extensions"
for ext in "$SOURCE"/*(N/); do
  if [[ -f "$ext/manifest.json" ]]; then
    rm -rf "$ROOT_DIR/Extensions/${ext:t}"
    ditto "$ext" "$ROOT_DIR/Extensions/${ext:t}"
    echo "staged ${ext:t}"
  fi
done
