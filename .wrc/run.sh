#!/bin/bash
set -o pipefail
cd "$(dirname "$0")/.."
export CMUX_BROWSER_TESTS=1
args=(); for f in "$@"; do args+=("webviews/$f"); done
bash scripts/ci/run-webviews-tests.sh "${args[@]}" 2>&1 | grep -v "^\s*at \|UtilityScript" | tail -600
