#!/usr/bin/env bash
echo "=== SUMMARY"
python3 tests/test_short_timeout_guard.py 2>&1 | tail -3
