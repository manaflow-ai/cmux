#!/usr/bin/env python3
"""Behavior tests for the changed-crate cmux-tui rustfmt check.

PR CI never ran cmux-tui.yml (dispatch only), so #18706 landed unformatted Rust
and broke base `cargo fmt --check`. cmux-tui-fmt-changed.py runs
`cargo fmt --check` on each package a change touches; these tests drive it on
a scratch repository with a fake cargo that records its calls.
"""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("cmux-tui-fmt-changed.py")
_spec = importlib.util.spec_from_file_location("git_fixture_env", SCRIPT.parents[2] / "tests/git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(git_fixture_env)
FAKE_CARGO = """#!/usr/bin/env bash
if [[ "$1" == metadata ]]; then
  cat "$CARGO_METADATA"
  exit 0
fi
printf '%s\\n' "$*" >> "$CARGO_LOG"
for arg in "$@"; do
  if [[ "$arg" == *"/${FAIL_PACKAGE:-none}/Cargo.toml" ]]; then
    if [[ -n "${DIFF_FILE:-}" ]]; then
      echo "Diff in ${arg%/Cargo.toml}/${DIFF_FILE}:3:"
    else
      echo "Diff in $arg"
    fi
    exit 1
  fi
done
"""
FAKE_RUSTFMT = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$RUSTFMT_LOG"
if [[ "${RUSTFMT_FAIL:-}" == 1 ]]; then
  echo "Diff in ${@: -1}:3:"
  exit 1
fi
"""


class FmtChangedTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.tmp = Path(temporary.name)
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
        git_fixture_env.init_repo(self.repo)
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD").strip()
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        cargo = bin_dir / "cargo"
        cargo.write_text(FAKE_CARGO)
        cargo.chmod(0o755)
        rustfmt = bin_dir / "rustfmt"
        rustfmt.write_text(FAKE_RUSTFMT)
        rustfmt.chmod(0o755)
        self.log = self.tmp / "cargo.log"
        self.rustfmt_log = self.tmp / "rustfmt.log"
        metadata = self.tmp / "metadata.json"
        metadata.write_text(json.dumps({
            "workspace_members": ["a", "b"],
            "packages": [
                {"id": name, "edition": edition, "manifest_path": str(self.repo / f"cmux-tui/crates/{name}/Cargo.toml")}
                for name, edition in (("a", "2024"), ("b", "2021"))
            ],
        }))
        self.env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "CARGO_LOG": str(self.log),
                    "RUSTFMT_LOG": str(self.rustfmt_log), "CARGO_METADATA": str(metadata)}

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

    def run_check(self, *args: str, fail: str | None = None, **extra: str) -> subprocess.CompletedProcess[str]:
        env = dict(self.env)
        env.pop("CMUX_NEXT_STYLE_GUARDS", None)
        env.update(extra)
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

    def test_a_warn_only_run_names_each_unformatted_file_in_a_warning(self) -> None:
        # Pull requests into feat-cmux-next only warn (CMUX_NEXT_STYLE_GUARDS=warn); the warning names the file and
        # line rustfmt would change, so the annotation sits on it instead of on the workflow.
        self.change("cmux-tui/crates/b/src/lib.rs")
        result = self.run_check("--base", self.base, fail="b", DIFF_FILE="src/lib.rs", CMUX_NEXT_STYLE_GUARDS="warn")
        self.assertNotEqual(result.returncode, 0, "the workflow step turns the exit code into a pass, not the script")
        self.assertIn("::warning file=cmux-tui/crates/b/src/lib.rs,line=3,title=cmux-tui rustfmt (warn-only)::",
                      result.stdout)
        self.assertNotIn("::error", result.stdout)

    def test_a_failing_run_names_the_file_in_an_error_and_a_nameless_diff_the_manifest(self) -> None:
        self.change("cmux-tui/crates/b/src/lib.rs")
        named = self.run_check("--base", self.base, fail="b", DIFF_FILE="src/lib.rs")
        self.assertIn("::error file=cmux-tui/crates/b/src/lib.rs,line=3,title=cmux-tui rustfmt::", named.stdout)
        nameless = self.run_check("--base", self.base, fail="b")
        self.assertIn("::error file=cmux-tui/crates/b/Cargo.toml,title=cmux-tui rustfmt::", nameless.stdout)

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

    def test_a_crate_with_one_it_test_binary_names_its_test_files_to_rustfmt(self) -> None:
        # tests/*.rs of a crate built as one `it` binary (#56677) are reached through a generated list
        # cargo fmt cannot follow, so the check names them; another crate's run is unchanged.
        self.write("cmux-tui/crates/a/tests/it/main.rs", "test_modules::modules!();\n")
        self.write("cmux-tui/crates/a/tests/one.rs", "#[test]\nfn one() {}\n")
        self.change("cmux-tui/crates/a/tests/two.rs", "#[test]\nfn two() {}\n")
        result = self.run_check("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.checked(), ["cmux-tui/crates/a/Cargo.toml"])
        self.assertNotIn("--", self.log.read_text().split())
        words = self.rustfmt_log.read_text().split()
        self.assertEqual(words[:3], ["--check", "--edition", "2024"])
        named = [str(Path(w).relative_to(self.repo)) for w in words[3:]]
        self.assertEqual(named, ["cmux-tui/crates/a/tests/one.rs", "cmux-tui/crates/a/tests/two.rs"])
        head = self.git("rev-parse", "HEAD").strip()
        self.change("cmux-tui/crates/b/src/lib.rs")
        self.log.unlink()
        self.run_check("--base", head)
        self.assertEqual(self.checked(), ["cmux-tui/crates/b/Cargo.toml"])
        self.assertNotIn("--", self.log.read_text().split())

    def test_generated_test_diff_fails_and_is_annotated(self) -> None:
        self.write("cmux-tui/crates/a/tests/it/main.rs", "test_modules::modules!();\n")
        self.change("cmux-tui/crates/a/tests/one.rs", "#[test]\nfn one() {}\n")
        result = self.run_check("--base", self.base, RUSTFMT_FAIL="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("::error file=cmux-tui/crates/a/tests/one.rs,line=3", result.stdout)

    def test_workspace_generated_tests_keep_each_edition_in_check_and_fix_modes(self) -> None:
        for name in ("a", "b"):
            self.write(f"cmux-tui/crates/{name}/tests/it/main.rs", "test_modules::modules!();\n")
            self.write(f"cmux-tui/crates/{name}/tests/one.rs", "#[test]\nfn one() {}\n")
        for mode in ([], ["--fix"]):
            with self.subTest(mode=mode):
                self.rustfmt_log.unlink(missing_ok=True)
                result = self.run_check("--it-tests-only", *mode)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = [line.split() for line in self.rustfmt_log.read_text().splitlines()]
                self.assertEqual(len(calls), 2)
                for call, (name, edition) in zip(calls, (("a", "2024"), ("b", "2021"))):
                    expected = ([] if mode else ["--check"]) + ["--edition", edition]
                    self.assertEqual(call[:-1], expected)
                    self.assertEqual(Path(call[-1]), self.repo / f"cmux-tui/crates/{name}/tests/one.rs")


if __name__ == "__main__":
    unittest.main()
