#!/bin/bash
set -euo pipefail

echo "ci_pre_xcodebuild: syncing and initializing submodules"
git submodule sync --recursive
git submodule update --init --recursive

if [ ! -f "vendor/bonsplit/Package.swift" ]; then
  echo "ci_pre_xcodebuild: missing vendor/bonsplit/Package.swift after submodule init" >&2
  exit 1
fi

echo "ci_pre_xcodebuild: vendor/bonsplit is ready"
