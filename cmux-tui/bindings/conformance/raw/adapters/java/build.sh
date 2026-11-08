#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDINGS_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/out}"
SOURCES_FILE="$OUT_DIR/sources.txt"

mkdir -p "$OUT_DIR"
find "$BINDINGS_DIR/java/src" "$SCRIPT_DIR/src" -name '*.java' -type f -print | sort >"$SOURCES_FILE"
javac --release 17 -d "$OUT_DIR" @"$SOURCES_FILE"
