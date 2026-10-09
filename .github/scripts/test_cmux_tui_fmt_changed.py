#!/usr/bin/env python3
"""Behavior tests for the changed-crate cmux-tui rustfmt check.

PR CI never ran cmux-tui.yml (dispatch only), so #18706 landed unformatted Rust
and broke base `cargo fmt --check`. cmux-tui-fmt-changed.py runs
`cargo fmt --check` on each package a change touches; these tests drive it on
a scratch repository with a fake cargo that records its calls.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("cmux-tui-fmt-changed.py")
FAKE_CARGO = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$CARGO_LOG"
for arg in "$@"; do
  if [[ "$arg" == *"/${FAIL_PACKAGE:-none}/Cargo.toml" ]]; then
    echo "Diff in $arg"
    exit 1
  fi
done
"""


class FmtChangedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / "repo"
        # The workspace root is a package too, as in the real tree.
        self.write("cmux-tui/Cargo.toml", '[package]\nname = "root"\n\n[workspace]\nmembers = ["crates/a", "crates/b"]\n')
        self.write("cmux-tui/src/main.rs", "fn main() {}\n")
        self.write("cmux-tui/rustfmt.toml", "max_width = 100\n")
        self.write("cmux-tui/crates/a/Cargo.toml", '[package]\nname = "a"\n')
        self.write("cmux-tui/crates/a/src/lib.rs", "pub fn a() {}\n")
        self.write("cmux-tui/crates/a/src/deep/mod.rs", "pub fn d() {}\n")
        self.write("cmux-tui/crates/b/Cargo.toml", '[package]\nname = "b"\n')
        self.write("cmux-tui/crates/b/src/lib.rs", "pub fn b() {}\n")
        # Its own workspace, outside the cmux-tui workspace members.
        self.write("cmux-tui/crates/ffi/Cargo.toml", '[package]\nname = "ffi"\n\n[workspace]\n')
        self.write("cmux-tui/crates/ffi/src/lib.rs", "pub fn f() {}\n")
        self.write("cmux-tui/target/debug/build/x/Cargo.toml", '[package]\nname = "built"\n')
        # Vendored upstream code keeps upstream formatting.
        self.write("cmux-tui/vendor/up/Cargo.toml", '[package]\nname = "up"\n')
        self.write("cmux-tui/vendor/up/src/lib.rs", "pub fn u() {}\n")
        self.write("README.md", "readme\n")
        (self.repo / ".gitignore").write_text("cmux-tui/target/\n")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD").strip()
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        cargo = bin_dir / "cargo"
        cargo.write_text(FAKE_CARGO)
        cargo.chmod(0o755)
        self.log = self.tmp / "cargo.log"
        self.env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "CARGO_LOG": str(self.log)}

    def write(self, path: str, text: str) -> None:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@t",
             "-c", "commit.gpgsign=false", *args],
            check=True, capture_output=True, text=True,
        ).stdout

    def change(self, path: str, text: str = "pub fn changed() {}\n") -> None:
        self.write(path, text)
        self.git("add", "-A")
        self.git("commit", "-qm", "change")

    def run_check(self, *args: str, fail: str | None = None) -> subprocess.CompletedProcess[str]:
        env = dict(self.env)
        if fail:
            env["FAIL_PACKAGE"] = fail
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--repo", str(self.repo), *args],
            env=env, capture_output=True, text=True,
        )

    def checked(self) -> list[str]:
        if not self.log.exists():
            return []
        manifests = []
        for line in self.log.read_text().splitlines():
            words = line.split()
            self.assertEqual(words[:2], ["fmt", "--check"], line)
            manifests.append(str(Path(words[words.index("--manifest-path") + 1]).relative_to(self.repo)))
        return manifests

    def test_a_changed_rust_file_checks_only_its_package(self) -> None:
        self.change("cmux-tui/crates/a/src/deep/mod.rs")
        result = self.run_check("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.checked(), ["cmux-tui/crates/a/Cargo.toml"])

    def test_each_touched_package_is_checked_once(self) -> None:
        self.write("cmux-tui/crates/a/src/lib.rs", "pub fn a2() {}\n")
        self.write("cmux-tui/crates/a/src/deep/mod.rs", "pub fn d2() {}\n")
        self.change("cmux-tui/crates/ffi/src/lib.rs")
        result = self.run_check("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sorted(self.checked()), ["cmux-tui/crates/a/Cargo.toml", "cmux-tui/crates/ffi/Cargo.toml"])

    def test_an_unformatted_package_fails_and_names_it(self) -> None:
        self.change("cmux-tui/crates/b/src/lib.rs")
        result = self.run_check("--base", self.base, fail="b")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cmux-tui/crates/b", result.stdout + result.stderr)
        self.assertIn("cargo fmt", result.stdout + result.stderr)

    def test_one_red_package_does_not_hide_the_others(self) -> None:
        self.write("cmux-tui/crates/a/src/lib.rs", "pub fn a2() {}\n")
        self.change("cmux-tui/crates/b/src/lib.rs")
        result = self.run_check("--base", self.base, fail="a")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sorted(self.checked()), ["cmux-tui/crates/a/Cargo.toml", "cmux-tui/crates/b/Cargo.toml"])

    def test_a_change_outside_rust_packages_checks_nothing(self) -> None:
        self.change("README.md", "new readme\n")
        result = self.run_check("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.checked(), [])

    def test_a_rustfmt_config_change_checks_every_package(self) -> None:
        self.change("cmux-tui/rustfmt.toml", "max_width = 90\n")
        result = self.run_check("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sorted(self.checked()), [
            "cmux-tui/Cargo.toml", "cmux-tui/crates/a/Cargo.toml", "cmux-tui/crates/b/Cargo.toml",
            "cmux-tui/crates/ffi/Cargo.toml"])

    def test_no_base_checks_every_tracked_package(self) -> None:
        for base in ([], ["--base", ""], ["--base", "0" * 40]):
            with self.subTest(base=base):
                self.log.unlink(missing_ok=True)
                result = self.run_check(*base)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                # Ignored build output is never a package to check.
                self.assertEqual(sorted(self.checked()), [
                    "cmux-tui/Cargo.toml", "cmux-tui/crates/a/Cargo.toml", "cmux-tui/crates/b/Cargo.toml",
                    "cmux-tui/crates/ffi/Cargo.toml"])

    def test_a_vendored_package_is_never_checked(self) -> None:
        self.change("cmux-tui/vendor/up/src/lib.rs")
        result = self.run_check("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.checked(), [])

    def test_a_deleted_package_is_skipped(self) -> None:
        self.git("rm", "-rq", "cmux-tui/crates/b")
        self.git("commit", "-qm", "drop b")
        result = self.run_check("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.checked(), [])


if __name__ == "__main__":
    unittest.main()
