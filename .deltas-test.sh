#!/usr/bin/env bash
python3 -m pip install -q pyyaml >/dev/null 2>&1 || true
python3 tests/test_nightly_deltas_sparse_checkout.py -v
