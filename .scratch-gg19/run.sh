#!/usr/bin/env bash
python3 tests/test_cmux_next_tour.py > "${FAST_CHECKS_OUT:-/tmp}/tour.log" 2>&1
