#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDINGS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OUT_DIR="${1:?output directory is required}"
SOURCES_FILE="$OUT_DIR/sources.txt"

mkdir -p "$OUT_DIR"
find "$BINDINGS_DIR/java/src/com/cmux" \
  -maxdepth 1 -name '*.java' -type f -print >"$SOURCES_FILE"
find "$BINDINGS_DIR/java/src/com/cmux/internal" "$SCRIPT_DIR/src" \
  -name '*.java' -type f -print >>"$SOURCES_FILE"
for source in Json JsonException SocketDiscovery UInt64; do
  printf '%s\n' \
    "$BINDINGS_DIR/java/src/com/cmux/raw/$source.java" >>"$SOURCES_FILE"
done
sort -o "$SOURCES_FILE" "$SOURCES_FILE"
javac --release 17 -d "$OUT_DIR" @"$SOURCES_FILE"
