#!/usr/bin/env python3
"""Behavior tests for the isolated cmux-tui-core test runner."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
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

    def test_ignored_only_inventory_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "all listed tests are ignored"):
            MODULE.partition_tests(["manual_probe"], ["manual_probe"])


class InventoryTests(unittest.TestCase):
    def test_ignored_inventory_uses_libtest_ignored_selector(self) -> None:
        with patch.object(
            MODULE.subprocess,
            "run",
            return_value=SimpleNamespace(stdout="manual_probe: test\n"),
        ) as run:
            self.assertEqual(MODULE.tests_in(Path("runner"), ignored=True), ["manual_probe"])

        run.assert_called_once_with(
            ["runner", "--list", "--ignored"],
            check=True,
            stdout=MODULE.subprocess.PIPE,
            text=True,
        )

    def test_empty_ignored_inventory_is_allowed(self) -> None:
        with patch.object(MODULE.subprocess, "run", return_value=SimpleNamespace(stdout="")):
            self.assertEqual(MODULE.tests_in(Path("empty"), ignored=True), [])


def write_fake_core(root: Path, red: set[str], a_exit: str = "exit 101") -> tuple[Path, Path]:
    """A fake cmux-tui-core library test binary and the cargo messages that name it.

    The binary lists `a_red_test` and `b_green_test`, ends each name in RED with A_EXIT
    (a shell command, `exit 101` by default), and records every test it runs in
    `ran.log`. Returns (messages, core_root).
    """
    core_root = root / "crates" / "cmux-tui-core"
    (core_root / "src").mkdir(parents=True)
    ran = root / "ran.log"
    binary = root / "cmux_tui_core-fake"
    red_cases = "".join(f"  {name}) echo \"test {name} ... FAILED\"; {a_exit} ;;\n" for name in sorted(red))
    binary.write_text(
        "#!/usr/bin/env bash\n"
        'if [ "$1" = --list ]; then\n'
        '  [ "$2" = --ignored ] && exit 0\n'
        "  printf 'a_red_test: test\\nb_green_test: test\\n'\n"
        "  exit 0\n"
        "fi\n"
        f'echo "$1" >> "{ran}"\n'
        'case "$1" in\n'
        f"{red_cases}"
        '  *) echo "test $1 ... ok" ;;\n'
        "esac\n",
        encoding="utf-8",
    )
    binary.chmod(0o755)
    messages = root / "messages.jsonl"
    messages.write_text(
        json.dumps({
            "reason": "compiler-artifact",
            "profile": {"test": True},
            "target": {"kind": ["lib"], "src_path": str(core_root / "src" / "lib.rs")},
            "executable": str(binary),
        }) + "\n",
        encoding="utf-8",
    )
    return messages, core_root


def die_by(signal_name: str) -> str:
    """A fake-test shell command that ends the test process by SIG<SIGNAL_NAME>.

    The process resets the signal to its default action first, so neither bash nor
    Python handles it and the runner sees a signal-ended child.
    """
    code = f"import os, signal; s = signal.SIG{signal_name}; signal.signal(s, signal.SIG_DFL); os.kill(os.getpid(), s)"
    return f"exec '{sys.executable}' -c '{code}'"


class RunAllTests(unittest.TestCase):
    def run_runner(self, red: set[str], a_exit: str = "exit 101") -> tuple[int, str, list[str]]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            messages, core_root = write_fake_core(root, red, a_exit)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(messages), str(core_root)],
                check=False,
                capture_output=True,
                text=True,
            )
            ran_log = root / "ran.log"
            ran = ran_log.read_text(encoding="utf-8").split() if ran_log.exists() else []
        return result.returncode, result.stdout + result.stderr, ran

    def test_a_red_core_test_does_not_stop_the_others(self) -> None:
        # One run must show every core failure: the runner used to stop at the first.
        code, output, ran = self.run_runner({"a_red_test"})
        self.assertEqual(ran, ["a_red_test", "b_green_test"], output)
        self.assertNotEqual(code, 0, output)
        self.assertIn("a_red_test", output)

    def test_a_cancelled_core_test_stops_the_run(self) -> None:
        # Exit 129, 130 or 143 is a hangup, an interrupt or a terminate (a cancelled job):
        # the next test must not start, and the runner must still fail.
        for a_exit in ("exit 129", "exit 130", "exit 143"):
            with self.subTest(a_exit=a_exit):
                code, output, ran = self.run_runner({"a_red_test"}, a_exit)
                self.assertEqual(ran, ["a_red_test"], output)
                self.assertNotEqual(code, 0, output)

    def test_a_cancel_signal_stops_the_run_with_a_nonzero_status(self) -> None:
        # A test that a signal ends has a negative returncode, and sys.exit of a negative
        # number is not a failure on every host: the runner exits with 128 + the signal.
        for signal_name, status in (("HUP", 129), ("INT", 130), ("TERM", 143)):
            with self.subTest(signal=signal_name):
                code, output, ran = self.run_runner({"a_red_test"}, die_by(signal_name))
                self.assertEqual(ran, ["a_red_test"], output)
                self.assertEqual(code, status, output)

    def test_a_crashed_core_test_does_not_stop_the_others(self) -> None:
        # A crash is a red like any other: the next test still runs, and the run fails.
        code, output, ran = self.run_runner({"a_red_test"}, die_by("ABRT"))
        self.assertEqual(ran, ["a_red_test", "b_green_test"], output)
        self.assertEqual(code, 134, output)

    def test_a_green_core_passes(self) -> None:
        code, output, ran = self.run_runner(set())
        self.assertEqual(ran, ["a_red_test", "b_green_test"], output)
        self.assertEqual(code, 0, output)


if __name__ == "__main__":
    unittest.main()
