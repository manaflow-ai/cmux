#!/usr/bin/env python3
"""Run each cmux-tui workspace Rust test in a fresh process."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


TESTABLE_TARGET_KINDS = frozenset({"lib", "bin", "test", "example"})
ALLOWED_EMPTY_TEST_TARGETS = frozenset({("cmux-tui", "bin")})
PROCESS_CLEANUP_GRACE_SECONDS = 1.0


@dataclass(frozen=True)
class TestBinary:
    path: Path
    target_name: str
    target_kinds: frozenset[str]
    package_root: Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("cargo_messages", type=Path)
    parser.add_argument("workspace_root", type=Path)
    return parser.parse_args()


def is_below(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def package_root_for(source: Path, workspace_root: Path) -> Path:
    for candidate in (source.parent, *source.parents):
        if not is_below(candidate, workspace_root):
            break
        if (candidate / "Cargo.toml").is_file():
            return candidate
    raise SystemExit(f"could not find a workspace package for {source}")


def test_binaries(cargo_messages: Path, workspace_root: Path) -> list[TestBinary]:
    binaries: dict[Path, TestBinary] = {}
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
            target_name = target.get("name")
            target_kinds = frozenset(target.get("kind", []))
            if not target_kinds.intersection(TESTABLE_TARGET_KINDS):
                continue
            source = message.get("target", {}).get("src_path")
            executable = message.get("executable")
            if not target_name or not source or not executable:
                continue

            source_path = Path(source).resolve()
            if not is_below(source_path, workspace_root):
                continue
            binary = TestBinary(
                path=Path(executable).resolve(),
                target_name=target_name,
                target_kinds=target_kinds,
                package_root=package_root_for(source_path, workspace_root),
            )
            previous = binaries.setdefault(binary.path, binary)
            if previous != binary:
                raise SystemExit(
                    f"cargo reported conflicting metadata for {binary.path}: "
                    f"{previous} and {binary}"
                )

    selected = sorted(
        binaries.values(),
        key=lambda binary: (
            str(binary.package_root),
            binary.target_name,
            str(binary.path),
        ),
    )
    if not selected:
        raise SystemExit("cargo did not report any cmux-tui workspace test binaries")

    required_targets = [
        ("cmux_tui_core", "lib"),
        ("cmux-tui", "bin"),
    ]
    for target_name, target_kind in required_targets:
        matches = [
            binary
            for binary in selected
            if binary.target_name == target_name and target_kind in binary.target_kinds
        ]
        if len(matches) != 1:
            raise SystemExit(
                f"expected one {target_name} {target_kind} test binary, "
                f"found {len(matches)}"
            )
    return selected


def tests_in(binary: TestBinary) -> list[str]:
    result = subprocess.run(
        [str(binary.path), "--list"],
        check=True,
        cwd=binary.package_root,
        stdout=subprocess.PIPE,
        text=True,
    )
    tests = []
    for line in result.stdout.splitlines():
        name, separator, kind = line.rpartition(": ")
        if separator and kind == "test":
            tests.append(name)
    if len(tests) != len(set(tests)):
        raise SystemExit(f"{binary.path.name} listed duplicate test names")
    return tests


def process_group_exists(group_id: int) -> bool:
    try:
        os.killpg(group_id, 0)
    except ProcessLookupError:
        return False
    return True


def terminate_process_group(group_id: int) -> None:
    if not process_group_exists(group_id):
        return

    try:
        os.killpg(group_id, signal.SIGTERM)
    except ProcessLookupError:
        return

    deadline = time.monotonic() + PROCESS_CLEANUP_GRACE_SECONDS
    while time.monotonic() < deadline:
        if not process_group_exists(group_id):
            return
        time.sleep(0.05)

    try:
        os.killpg(group_id, signal.SIGKILL)
    except ProcessLookupError:
        return
    print(f"Cleaned surviving child process group {group_id}", flush=True)


def run_test(binary: TestBinary, test_name: str) -> None:
    command = [str(binary.path), test_name, "--exact", "--test-threads=1"]
    process = subprocess.Popen(
        command,
        cwd=binary.package_root,
        start_new_session=True,
    )
    try:
        return_code = process.wait()
    finally:
        terminate_process_group(process.pid)
    if return_code != 0:
        raise subprocess.CalledProcessError(return_code, command)


def main() -> int:
    args = parse_args()
    workspace_root = args.workspace_root.resolve()
    binaries = test_binaries(args.cargo_messages, workspace_root)
    total = 0
    for binary in binaries:
        tests = tests_in(binary)
        if not tests:
            allowed_empty = any(
                (binary.target_name, target_kind) in ALLOWED_EMPTY_TEST_TARGETS
                for target_kind in binary.target_kinds
            )
            if not allowed_empty:
                kinds = ",".join(sorted(binary.target_kinds))
                raise SystemExit(
                    f"{binary.target_name} ({kinds}) unexpectedly listed no tests"
                )
            print(f"No tests in known empty target {binary.target_name}; skipping its harness")
            continue
        print(
            f"Running {len(tests)} tests from {binary.target_name} "
            "in fresh processes"
        )
        for index, test_name in enumerate(tests, start=1):
            print(f"[{index}/{len(tests)}] {test_name}", flush=True)
            run_test(binary, test_name)
            total += 1
    if total == 0:
        raise SystemExit("cmux-tui workspace test binaries listed no tests")
    print(f"Passed {total} isolated cmux-tui workspace tests")
    return 0


if __name__ == "__main__":
    sys.exit(main())
