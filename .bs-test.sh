#!/usr/bin/env bash
set -o pipefail
python3 tests/test_nightly_build_state.py -v > /tmp/bs.out 2>&1; rc=$?
grep -E "^test_the_|^(FAIL|ERROR):|^Ran |^OK|^FAILED|AssertionError|skipped" /tmp/bs.out | head -30
echo "BS_RC=$rc"
exit $rc
