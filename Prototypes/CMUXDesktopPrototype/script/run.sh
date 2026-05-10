#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

xcodebuildmcp macos build-and-run \
  --workspace-path "$ROOT/CMUXDesktopPrototype.xcworkspace" \
  --scheme CMUXDesktopPrototype \
  --configuration Debug \
  --derived-data-path /tmp/cmux-desktop-prototype
