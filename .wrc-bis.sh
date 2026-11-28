#!/bin/bash
set -uo pipefail
P="$1"; shift
git apply -R --whitespace=nowarn ".bis/$P.patch" || { echo "APPLY FAILED $P"; exit 4; }
cd webviews
bun install --frozen-lockfile > /tmp/wrc-install.log 2>&1 || { tail -30 /tmp/wrc-install.log; exit 3; }
export CMUX_WEB_TEST_FILES="$(tr ',' '\n' <<<"$1")"
bash ../scripts/ci/run-webviews-tests.sh
