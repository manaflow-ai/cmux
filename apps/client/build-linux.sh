#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ENV_FILE="$ROOT_DIR/.env.production"
if [ ! -f "$ENV_FILE" ]; then
  ENV_FILE="$ROOT_DIR/.env"
fi

if [ -f "$ENV_FILE" ]; then
  echo "Using env file: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

rm -rf dist-electron
rm -rf out

ensure_native_core_built() {
  local native_dir="$ROOT_DIR/apps/server/native/core"
  echo "Ensuring native Rust addon (.node) is built for Linux..."

  # Remove stale Linux binaries to avoid bundling mixed architectures
  find "$native_dir" -maxdepth 1 -name 'cmux_native_core.linux-*.node' -delete 2>/dev/null || true

  (
    cd "$native_dir"
    bunx --bun @napi-rs/cli build --platform --release
  )

  shopt -s nullglob
  local linux_nodes=("$native_dir"/cmux_native_core.linux-*.node)
  shopt -u nullglob

  if [ ${#linux_nodes[@]} -eq 0 ]; then
    echo "ERROR: Native addon build did not produce a Linux .node binary." >&2
    exit 1
  fi

  echo "Found native binary: ${linux_nodes[0]##*/}"
}

if [ ! -d "node_modules" ]; then
  echo "Installing dependencies with Bun..."
  bun install --frozen-lockfile
fi

ensure_native_core_built

echo "Generating icons..."
node ./scripts/generate-icons.mjs

echo "Building renderer with electron-vite..."
bunx electron-vite build -c electron.vite.config.ts

echo "Packaging Linux artifacts with electron-builder..."
bunx electron-builder --linux --config electron-builder.json

echo "Build complete. Outputs in $(pwd)/dist-electron"
