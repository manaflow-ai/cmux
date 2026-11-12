#!/usr/bin/env python3
"""Run each cmux-tui-core Rust test in a fresh process, several processes at a time."""

from __future__ import annotations

import argparse
from collections.abc import Callable
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import sys
import threading


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


def jobs() -> int:
    """How many test processes run at once: CMUX_TUI_CORE_TEST_JOBS, else half the CPUs, 1-8."""
    raw = os.environ.get("CMUX_TUI_CORE_TEST_JOBS", "").strip()
    if raw:
        value = int(raw)
        if value < 1:
            raise SystemExit(f"CMUX_TUI_CORE_TEST_JOBS must be at least 1, not {raw}")
        return value
    return min(8, max(1, (os.cpu_count() or 2) // 2))


class Pool:
    """Runs each test in its own process, `jobs` at a time, and stops every worker on a cancel.

    The lock guards the running processes and the stop flag, which the worker threads and a
    cancel share; the printing lock keeps each test's output in one block.
    """

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.stopped = False
        self.running: set[subprocess.Popen[bytes]] = set()

    def run(
        self, binary: Path, test_name: str, started: Callable[[str], None]
    ) -> tuple[int, bytes] | None:
        """The test's exit status and output, or None when a cancel stopped the run first.

        `started` is told the test's name when its process starts, so a job cancelled while
        tests run still shows which ones were running.
        """
        with self.lock:
            if self.stopped:
                return None
            started(test_name)
            process = subprocess.Popen(
                [str(binary), test_name, "--exact", "--test-threads=1"],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            self.running.add(process)
        output, _ = process.communicate()
        with self.lock:
            self.running.discard(process)
        status = exit_status(process.returncode)
        if status in CANCEL_STATUSES:
            self.stop()
        return status, output

    def stop(self) -> None:
        """Starts no other test and ends every running one."""
        with self.lock:
            self.stopped = True
            for process in self.running:
                if process.poll() is None:
                    process.terminate()


def main() -> int:
    args = parse_args()
    core_root = args.core_root.resolve()
    binaries = test_binaries(args.cargo_messages, core_root)
    skipped = 0
    work: list[tuple[Path, str]] = []
    for binary in binaries:
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
        work.extend((binary, test_name) for test_name in tests)
    workers = jobs()
    print(f"Running {len(work)} tests, {workers} at a time, each in its own process", flush=True)
    # Every core test runs, so one run shows every red; the first red in test order is
    # returned. A cancelled test stops the run: no other test starts, and running ones end.
    pool, printing = Pool(), threading.Lock()
    results: dict[int, int] = {}
    done = 0

    def started(test_name: str) -> None:
        with printing:
            print(f"started {test_name}", flush=True)

    def one(at: int) -> None:
        nonlocal done
        binary, test_name = work[at]
        result = pool.run(binary, test_name, started)
        if result is None:
            return
        status, output = result
        with printing:
            done += 1
            print(f"[{done}/{len(work)}] {test_name} exited {status}", flush=True)
            sys.stdout.buffer.write(output)
            sys.stdout.flush()
            results[at] = status
            if status != 0:
                print(f"::error::{test_name} in {binary.name} exited {status}", file=sys.stderr)
            if status in CANCEL_STATUSES:
                print(f"Stopping: {test_name} was cancelled (exit {status})", file=sys.stderr)

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
            for future in [executor.submit(one, at) for at in range(len(work))]:
                future.result()
    except BaseException:
        pool.stop()
        raise
    failed = [(at, status) for at, status in sorted(results.items()) if status != 0]
    passed = sum(1 for status in results.values() if status == 0)
    print(f"Passed {passed} isolated cmux-tui-core tests")
    print(f"Skipped {skipped} ignored/manual cmux-tui-core tests")
    if len(results) < len(work):
        print(f"Not run after a cancel: {len(work) - len(results)} tests", file=sys.stderr)
    if failed:
        print(f"Failed {len(failed)} isolated cmux-tui-core tests:", file=sys.stderr)
        for at, status in failed:
            binary, test_name = work[at]
            print(f"  {test_name} in {binary.name} exited {status}", file=sys.stderr)
        return failed[0][1]
    return 0


if __name__ == "__main__":
    sys.exit(main())
