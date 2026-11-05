#!/usr/bin/env bash
python3 tests/test_ci_workflow_guards_are_wired.py; rc=$?; echo "WIRED_RC=$rc"
python3 tests/test_nightly_deltas_sparse_checkout.py 2>&1 | tail -3
exit $rc
