#!/usr/bin/env bash
out="${FAST_CHECKS_OUT:-/tmp}"
python3 scripts/check-test-determinism.py --self-test > "$out/selftest.log" 2>&1; echo "SELFTEST rc=$?"; tail -3 "$out/selftest.log"
python3 tests/test_guards_new_reds.py > "$out/gnr.log" 2>&1; echo "GNR rc=$?"; tail -3 "$out/gnr.log"
scripts/ci/guards-local.sh --no-stamp --keep-going --jobs "$(getconf _NPROCESSORS_ONLN)" --results "$out/head.json" > "$out/guards.log" 2>&1
rc=$?
grep -E "^\s*FAIL |steps passed" "$out/guards.log"
exit $rc
