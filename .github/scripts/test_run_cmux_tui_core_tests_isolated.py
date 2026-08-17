#!/usr/bin/env python3
"""Behavior tests for the isolated cmux-tui-core test runner."""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import unittest


SCRIPT = Path(__file__).with_name("run-cmux-tui-core-tests-isolated.py")
SPEC = importlib.util.spec_from_file_location("isolated_runner", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT}")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PartitionTests(unittest.TestCase):
    def test_ignored_tests_are_manual_and_not_runnable(self) -> None:
        runnable, ignored = MODULE.partition_tests(
            ["active_test", "manual_probe"],
            ["manual_probe"],
        )
        self.assertEqual(runnable, ["active_test"])
        self.assertEqual(ignored, ["manual_probe"])

    def test_unknown_ignored_test_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            MODULE.partition_tests(["active_test"], ["missing_probe"])


class InventoryTests(unittest.TestCase):
    def test_empty_ignored_inventory_is_allowed(self) -> None:
        with patch.object(MODULE.subprocess, "run", return_value=SimpleNamespace(stdout="")):
            self.assertEqual(MODULE.tests_in(Path("empty"), ignored=True), [])


if __name__ == "__main__":
    unittest.main()
