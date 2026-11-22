#!/usr/bin/env python3
"""Run each cmux-tui-core Rust test in a fresh process."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("cargo_messages", type=Path)
    parser.add_argument("core_root", type=Path)
    return parser.parse_args()


def is_below(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def test_binaries(cargo_messages: Path, core_root: Path) -> list[Path]:
    binaries: dict[Path, set[str]] = {}
    with cargo_messages.open(encoding="utf-8") as messages:
        for line in messages:
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if message.get("reason") != "compiler-artifact":
                continue
            if not message.get("profile", {}).get("test"):
                continue

            target = message.get("target", {})
            kinds = set(target.get("kind", []))
            if not kinds.intersection({"lib", "test"}):
                continue
            source = target.get("src_path")
            executable = message.get("executable")
            if not source or not executable:
                continue
            if not is_below(Path(source).resolve(), core_root):
                continue
            binaries.setdefault(Path(executable).resolve(), set()).update(kinds)

    library_binaries = [path for path, kinds in binaries.items() if "lib" in kinds]
    if len(library_binaries) != 1:
        raise SystemExit(
            "expected one cmux-tui-core library test binary, "
            f"found {len(library_binaries)}"
        )
    if not binaries:
        raise SystemExit("cargo did not report any cmux-tui-core test binaries")
    return sorted(binaries)


def tests_in(binary: Path, *, ignored: bool = False) -> list[str]:
    command = [str(binary), "--list"]
    if ignored:
        command.append("--ignored")
    result = subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    tests = []
    for line in result.stdout.splitlines():
        name, separator, kind = line.rpartition(": ")
        if separator and kind == "test":
            tests.append(name)
    if not tests and ignored:
        return []
    if not tests:
        raise SystemExit(f"{binary.name} did not list any tests")
    if len(tests) != len(set(tests)):
        raise SystemExit(f"{binary.name} listed duplicate test names")
    return tests


def partition_tests(all_tests: list[str], ignored_tests: list[str]) -> tuple[list[str], list[str]]:
    all_test_set = set(all_tests)
    ignored_test_set = set(ignored_tests)
    unknown = sorted(ignored_test_set - all_test_set)
    if unknown:
        raise ValueError(
            "libtest reported ignored tests that were absent from its complete list: "
            + ", ".join(unknown)
        )
    ignored = [test_name for test_name in all_tests if test_name in ignored_test_set]
    runnable = [test_name for test_name in all_tests if test_name not in ignored_test_set]
    if all_tests and not runnable:
        raise ValueError(
            f"all listed tests are ignored ({len(ignored)}); refusing an ignored-only run"
        )
    return runnable, ignored


# Exit statuses of a test that a hangup, an interrupt or a terminate ended (a cancelled
# job), as an exit code or as a signal. A crash (SIGABRT, SIGSEGV) is a red and does not stop.
CANCEL_STATUSES = frozenset({129, 130, 143})


def exit_status(returncode: int) -> int:
    """A positive exit status: a signal-ended child (negative returncode) maps to 128 + signal."""
    return 128 - returncode if returncode < 0 else returncode


def main() -> int:
    args = parse_args()
    core_root = args.core_root.resolve()
    binaries = test_binaries(args.cargo_messages, core_root)
    total = 0
    skipped = 0
    # Every core test runs, so one run shows every red; the first red status is returned.
    # A cancelled test stops the run: the next test must not start.
    failed: list[tuple[str, str, int]] = []
    stopped = False
    for binary in binaries:
        if stopped:
            break
        all_tests = tests_in(binary)
        ignored_tests = tests_in(binary, ignored=True)
        try:
            tests, ignored = partition_tests(all_tests, ignored_tests)
        except ValueError as error:
            raise SystemExit(str(error)) from error
        print(f"Running {len(tests)} tests from {binary.name} in fresh processes")
        if ignored:
            print(f"Skipping {len(ignored)} ignored/manual tests from {binary.name}:")
            for test_name in ignored:
                print(f"  {test_name}")
            skipped += len(ignored)
        for index, test_name in enumerate(tests, start=1):
            print(f"[{index}/{len(tests)}] {test_name}", flush=True)
            returncode = subprocess.run(
                [str(binary), test_name, "--exact", "--test-threads=1"],
                check=False,
            ).returncode
            status = exit_status(returncode)
            if status != 0:
                print(f"::error::{test_name} in {binary.name} exited {status}", file=sys.stderr)
                failed.append((binary.name, test_name, status))
                if status in CANCEL_STATUSES:
                    print(f"Stopping: {test_name} was cancelled (exit {status})", file=sys.stderr)
                    stopped = True
                    break
                continue
            total += 1
    print(f"Passed {total} isolated cmux-tui-core tests")
    print(f"Skipped {skipped} ignored/manual cmux-tui-core tests")
    if failed:
        print(f"Failed {len(failed)} isolated cmux-tui-core tests:", file=sys.stderr)
        for binary_name, test_name, status in failed:
            print(f"  {test_name} in {binary_name} exited {status}", file=sys.stderr)
        return failed[0][2]
    return 0


if __name__ == "__main__":
    sys.exit(main())
