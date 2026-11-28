#!/bin/bash
set -o pipefail
cd "$(dirname "$0")/.."
export CMUX_BROWSER_TESTS=1
args=(); for f in "$@"; do args+=("webviews/$f"); done
bash scripts/ci/run-webviews-tests.sh "${args[@]}" 2>&1 | grep -v "^\s*at \|UtilityScript\|\[Getter\|\[Function\|^\s*[A-Z_]*: [0-9]*,$" | grep -v "^\s\{10,\}"
