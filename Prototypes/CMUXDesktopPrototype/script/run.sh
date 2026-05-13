#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="$ROOT/DerivedData"

xcodebuildmcp macos build-and-run \
  --workspace-path "$ROOT/CMUXDesktopPrototype.xcworkspace" \
  --scheme CMUXDesktopPrototype \
  --configuration Debug \
  --derived-data-path "$DERIVED_DATA_PATH"
