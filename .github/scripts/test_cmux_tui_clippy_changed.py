#!/usr/bin/env python3
"""Behavior tests for the changed-package cmux-tui clippy check.

PR CI never ran cmux-tui.yml (dispatch only), so #23163 and #23372 landed clippy
reds in cmux-tui/crates/cmux-tui/tests/ and broke base clippy. cmux-tui-clippy-changed.py
runs `cargo clippy --all-targets -D warnings` on each workspace package a change
touches and on the members depending on it; these tests drive it on a scratch
repository with a fake cargo that answers `cargo metadata` from the test's
workspace and records its other calls. With --panic-ratchet it runs the panic
ratchet on the same packages (only cmux-tui.yml ran it, so #27935 landed two
acpmux indexing_slicing hits); a fake ratchet records how it is called.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("cmux-tui-clippy-changed.py")
RATCHET = Path(__file__).resolve().parents[2] / "scripts/cmux-next/rust_panic_ratchet.py"
FAKE_CARGO = """#!/usr/bin/env bash
if [[ "$1" == metadata ]]; then
  [[ -n "${METADATA_FAILS:-}" ]] && { echo "error: failed to parse manifest" >&2; exit 101; }
  cat "$CARGO_METADATA"
  exit
fi
printf '%s\\n' "$*" >> "$CARGO_LOG"
[[ -n "${HEAD_LOG:-}" ]] && git rev-parse HEAD >> "$HEAD_LOG"
for arg in "$@"; do
  if [[ "$arg" == "${FAIL_PACKAGE:-none}" ]]; then
    echo "error: this call to clone can be replaced with std::slice::from_ref"
    exit 101
  fi
  if [[ "$arg" == --message-format=json ]]; then
    echo '{"reason":"build-finished","success":true}'
  fi
done
"""
# The repository's own ratchet answers --flags and records every other call.
FAKE_RATCHET = """import os, sys
if sys.argv[1:] == ["--flags"]:
    print("-W clippy::unwrap_used -W clippy::indexing_slicing")
    sys.exit(0)
with open(os.environ["RATCHET_LOG"], "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\\n")
sys.exit(int(os.environ.get("RATCHET_RC", "0")))
"""
LINT = ["--all-targets", "--", "-D", "warnings"]
PANIC = ["--message-format=json", "--", "-W", "clippy::unwrap_used", "-W", "clippy::indexing_slicing"]


class ClippyChangedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / "repo"
        # The workspace root is a package too, as in the real tree.
        self.write("cmux-tui/Cargo.toml", '[package]\nname = "cmux-root"\n\n[workspace]\nmembers = ["crates/*"]\nexclude = ["crates/ffi"]\n')
        self.write("cmux-tui/Cargo.lock", "# lock\n")
        self.write("cmux-tui/src/main.rs", "fn main() {}\n")
        self.write("cmux-tui/crates/a/Cargo.toml", '[package]\nname = "pkg-a"\n')
        self.write("cmux-tui/crates/a/src/lib.rs", "pub fn a() {}\n")
        self.write("cmux-tui/crates/a/tests/journey.rs", "#[test]\nfn t() {}\n")
        self.write("cmux-tui/crates/b/Cargo.toml", '[package]\nname = "pkg-b"\n')
        self.write("cmux-tui/crates/b/src/lib.rs", "pub fn b() {}\n")
        # pkg-c uses pkg-a in its tests only, and pkg-d uses pkg-c.
        self.write("cmux-tui/crates/c/Cargo.toml", '[package]\nname = "pkg-c"\n')
        self.write("cmux-tui/crates/c/src/lib.rs", "pub fn c() {}\n")
        self.write("cmux-tui/crates/d/Cargo.toml", '[package]\nname = "pkg-d"\n')
        self.write("cmux-tui/crates/d/src/lib.rs", "pub fn d() {}\n")
        # Its own workspace, outside the cmux-tui workspace members.
        self.write("cmux-tui/crates/ffi/Cargo.toml", '[package]\nname = "ffi"\n\n[workspace]\n')
        self.write("cmux-tui/crates/ffi/src/lib.rs", "pub fn f() {}\n")
        self.write("cmux-tui/vendor/up/Cargo.toml", '[package]\nname = "up"\n')
        self.write("cmux-tui/vendor/up/src/lib.rs", "pub fn u() {}\n")
        self.write("README.md", "readme\n")
        self.write("scripts/cmux-next/rust_panic_ratchet.py", FAKE_RATCHET)
        self.write("scripts/cmux-next/rust-panic-baseline.json", "{}\n")
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
        self.metadata = self.tmp / "metadata.json"
        self.members = {"": "cmux-root", "crates/a": "pkg-a", "crates/b": "pkg-b", "crates/c": "pkg-c", "crates/d": "pkg-d"}
        self.uses = {"pkg-c": [("crates/a", "dev")], "pkg-d": [("crates/c", None)], "cmux-root": [("vendor/up", None)]}
        # The root package is a binary only; the crates are libraries.
        self.kinds = {"cmux-root": ["bin"]}
        self.ratchet_log = self.tmp / "ratchet.log"
        self.env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "CARGO_LOG": str(self.log),
                    "CARGO_METADATA": str(self.metadata), "RATCHET_LOG": str(self.ratchet_log)}

    def write_metadata(self) -> None:
        """`cargo metadata --no-deps` for the members and path dependencies the test declares."""
        root = self.repo / "cmux-tui"
        packages = [{
            "id": f"path+file://{root / path}#{name}",
            "name": name,
            "manifest_path": str(root / path / "Cargo.toml"),
            # Each also uses a registry crate, which has no path.
            "dependencies": [{"name": dep, "kind": kind, "path": str(root / dep)} for dep, kind in self.uses.get(name, [])]
            + [{"name": "serde", "kind": None, "source": "registry+https://github.com/rust-lang/crates.io-index"}],
            "targets": [{"name": name, "kind": [kind]} for kind in self.kinds.get(name, ["lib"])],
        } for path, name in self.members.items()]
        self.metadata.write_text(json.dumps({"packages": packages, "workspace_members": [p["id"] for p in packages]}))

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

    def run_check(self, *args: str, fail: str | None = None, env_extra: dict | None = None) -> subprocess.CompletedProcess[str]:
        self.write_metadata()
        env = {**self.env, **(env_extra or {})}
        if fail:
            env["FAIL_PACKAGE"] = fail
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--repo", str(self.repo), *args],
            env=env, capture_output=True, text=True,
        )

    def calls(self) -> list[list[str]]:
        if not self.log.exists():
            return []
        return [line.split() for line in self.log.read_text().splitlines()]

    def ratchet_calls(self) -> list[list[str]]:
        if not self.ratchet_log.exists():
            return []
        return [line.split() for line in self.ratchet_log.read_text().splitlines()]

    def run_ratchet(self, *args: str, rc: int = 0) -> tuple[subprocess.CompletedProcess[str], Path]:
        out = self.tmp / "out" / "panic-clippy.jsonl"
        result = self.run_check(*args, "--panic-ratchet", str(out), env_extra={"RATCHET_RC": str(rc)})
        return result, out

    def test_a_changed_integration_test_lints_its_package_with_all_targets(self) -> None:
        # #23163's shape: only a file under the package's tests/ changed.
        self.change("cmux-tui/crates/a/tests/journey.rs", "#[test]\nfn t2() {}\n")
        result = self.run_check("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [["clippy", "--locked", "--keep-going", "-p", "pkg-a", "-p", "pkg-c", "-p", "pkg-d", *LINT]])

    def test_a_lint_in_a_touched_package_fails_and_names_it(self) -> None:
        self.change("cmux-tui/crates/a/tests/journey.rs", "#[test]\nfn t2() {}\n")
        result = self.run_check("--base", self.base, fail="pkg-a")
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error title=cmux-tui clippy::", result.stdout)
        self.assertIn("pkg-a", result.stdout)

    def test_every_touched_member_is_linted_in_one_keep_going_run(self) -> None:
        self.write("cmux-tui/crates/b/src/lib.rs", "pub fn b2() {}\n")
        self.write("cmux-tui/src/main.rs", "fn main() { let _ = 1; }\n")
        self.change("cmux-tui/crates/a/src/lib.rs")
        result = self.run_check("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [[
            "clippy", "--locked", "--keep-going", "-p", "cmux-root", "-p", "pkg-a", "-p", "pkg-b",
            "-p", "pkg-c", "-p", "pkg-d", *LINT]])

    def test_members_depending_on_a_changed_package_are_linted_too(self) -> None:
        # A change to pkg-a can break pkg-c's tests (a dev-dependency) and, through pkg-c, pkg-d.
        self.change("cmux-tui/crates/a/src/lib.rs")
        result = self.run_check("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [["clippy", "--locked", "--keep-going", "-p", "pkg-a", "-p", "pkg-c", "-p", "pkg-d", *LINT]])
        self.assertIn("pkg-c, pkg-d depend on pkg-a", result.stdout)

    def test_a_failing_cargo_metadata_fails_the_check_without_linting(self) -> None:
        self.change("cmux-tui/crates/a/src/lib.rs")
        result = self.run_check("--base", self.base, env_extra={"METADATA_FAILS": "1"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error title=cmux-tui clippy::`cargo metadata --no-deps` failed", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_a_package_nothing_depends_on_is_linted_alone(self) -> None:
        self.change("cmux-tui/crates/d/src/lib.rs")
        result = self.run_check("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [["clippy", "--locked", "--keep-going", "-p", "pkg-d", *LINT]])

    def test_a_package_cargo_does_not_list_as_a_member_is_named_not_linted_here(self) -> None:
        self.change("cmux-tui/crates/ffi/src/lib.rs")
        result = self.run_check("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertIn("cmux-tui/crates/ffi is not a cmux-tui workspace member", result.stdout)

    def test_workspace_wide_inputs_lint_the_whole_workspace(self) -> None:
        for path, text in (("cmux-tui/Cargo.lock", "# lock 2\n"), ("cmux-tui/clippy.toml", "msrv = \"1.91\"\n"),
                           ("cmux-tui/rust-toolchain.toml", "[toolchain]\n")):
            with self.subTest(path=path):
                base = self.git("rev-parse", "HEAD").strip()
                self.log.unlink(missing_ok=True)
                self.change(path, text)
                result = self.run_check("--base", base)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.calls(), [["clippy", "--locked", "--keep-going", "--workspace", *LINT]])

    def test_no_usable_base_lints_the_whole_workspace(self) -> None:
        for base in ([], ["--base", ""], ["--base", "0" * 40], ["--base", "f" * 40]):
            with self.subTest(base=base):
                self.log.unlink(missing_ok=True)
                result = self.run_check(*base)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.calls(), [["clippy", "--locked", "--keep-going", "--workspace", *LINT]])

    def test_changes_outside_workspace_rust_lint_nothing(self) -> None:
        for path in ("README.md", "cmux-tui/vendor/up/src/lib.rs"):
            with self.subTest(path=path):
                base = self.git("rev-parse", "HEAD").strip()
                self.log.unlink(missing_ok=True)
                self.change(path, "changed\n")
                result = self.run_check("--base", base)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.calls(), [])

    def test_deleting_a_package_lints_the_remaining_workspace(self) -> None:
        self.git("rm", "-rq", "cmux-tui/crates/b")
        del self.members["crates/b"]
        self.write("cmux-tui/Cargo.toml", '[package]\nname = "cmux-root"\n\n[workspace]\nmembers = ["crates/*"]\nexclude = ["crates/ffi", "crates/b"]\n')
        self.git("add", "-A")
        self.git("commit", "-qm", "drop b")
        result = self.run_check("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # The workspace manifest changed with it, so the whole (remaining) workspace is linted.
        self.assertEqual(self.calls(), [["clippy", "--locked", "--keep-going", "--workspace", *LINT]])

    def test_the_panic_ratchet_lints_the_production_targets_of_the_changed_packages(self) -> None:
        # #27935's shape: a library's source gained an indexing hit.
        self.change("cmux-tui/crates/a/src/lib.rs")
        result, out = self.run_ratchet("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [["clippy", "--locked", "-p", "pkg-a", "-p", "pkg-c", "-p", "pkg-d",
                                         "--lib", "--bins", *PANIC]])
        self.assertIn('"build-finished"', out.read_text())
        self.assertEqual(self.ratchet_calls(), [["--repo", str(self.repo.resolve()), "--clippy-json", str(out)]])

    def test_a_red_panic_ratchet_fails_the_check_and_names_the_packages(self) -> None:
        self.change("cmux-tui/crates/d/src/lib.rs")
        result, _ = self.run_ratchet("--base", self.base, rc=1)
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error title=cmux-tui panic ratchet::", result.stdout)
        self.assertIn("pkg-d", result.stdout)

    def test_the_panic_ratchet_drops_lib_when_no_selected_package_has_one(self) -> None:
        # Cargo refuses `-p bin-only --lib`.
        self.change("cmux-tui/src/main.rs", "fn main() { let _ = 2; }\n")
        result, _ = self.run_ratchet("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [["clippy", "--locked", "-p", "cmux-root", "--bins", *PANIC]])

    def test_the_panic_ratchet_covers_the_whole_workspace_for_workspace_wide_inputs(self) -> None:
        self.change("cmux-tui/Cargo.lock", "# lock 2\n")
        result, _ = self.run_ratchet("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [["clippy", "--locked", "--workspace", "--lib", "--bins", *PANIC]])
        self.assertEqual(len(self.ratchet_calls()), 1)

    def test_the_panic_ratchet_runs_for_a_baseline_only_change(self) -> None:
        # The baseline is a workspace-wide ratchet input; it must not take the no-package fast path.
        self.change("scripts/cmux-next/rust-panic-baseline.json", "{\"changed\": true}\n")
        result, _ = self.run_ratchet("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [["clippy", "--locked", "--workspace", "--lib", "--bins", *PANIC]])
        self.assertEqual(len(self.ratchet_calls()), 1)

    def test_the_panic_ratchet_skips_a_change_with_no_workspace_rust(self) -> None:
        self.change("README.md", "changed\n")
        result, _ = self.run_ratchet("--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.ratchet_calls(), [])

    def test_compare_base_lints_the_same_packages_at_the_base_first(self) -> None:
        # cmux-next fast gates: a row lowered on the tip since the PR's own ratchet ran (#28182); the base's
        # own count over the row is the base's red, so the ratchet gets the base run to compare with.
        self.change("cmux-tui/crates/a/src/lib.rs")
        head = self.git("rev-parse", "HEAD").strip()
        heads = self.tmp / "heads.log"
        out = self.tmp / "out" / "panic-clippy.jsonl"
        result = self.run_check("--base", self.base, "--panic-ratchet", str(out), "--compare-base",
                                env_extra={"HEAD_LOG": str(heads)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lint = ["clippy", "--locked", "-p", "pkg-a", "-p", "pkg-c", "-p", "pkg-d", "--lib", "--bins", *PANIC]
        self.assertEqual(self.calls(), [lint, lint])
        self.assertEqual(heads.read_text().split(), [self.base, head])
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), head, "the checkout is back on HEAD")
        base_out = out.with_name(out.name + ".base")
        self.assertIn('"build-finished"', base_out.read_text())
        self.assertEqual(self.ratchet_calls(), [["--repo", str(self.repo.resolve()), "--clippy-json", str(out),
                                                 "--base-clippy-json", str(base_out)]])

    def test_compare_base_returns_to_head_when_the_base_lint_cannot_start(self) -> None:
        self.change("cmux-tui/crates/a/src/lib.rs")
        head = self.git("rev-parse", "HEAD").strip()
        out = self.tmp / "out" / "panic-clippy.jsonl"
        out.parent.mkdir(parents=True)
        out.with_name(out.name + ".base").mkdir()  # opening the base JSONL fails
        result = self.run_check("--base", self.base, "--panic-ratchet", str(out), "--compare-base")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), head)

    def test_compare_base_needs_a_base(self) -> None:
        self.change("cmux-tui/crates/a/src/lib.rs")
        result, out = self.run_ratchet("--compare-base")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [["clippy", "--locked", "--workspace", "--lib", "--bins", *PANIC]])
        self.assertEqual(self.ratchet_calls(), [["--repo", str(self.repo.resolve()), "--clippy-json", str(out)]])


def clippy_jsonl(hits: int, finished: bool = True, lint: str = "indexing_slicing") -> str:
    """A ratchet clippy run of the `acpmux` crate with `hits` hits of `lint` (each on its own line)."""
    lines = [{"reason": "compiler-artifact", "package_id": "path+file:///w/cmux-tui/crates/acpmux#0.1.0",
              "target": {"kind": ["lib"]}}]
    lines += [{"reason": "compiler-message", "package_id": "path+file:///w/cmux-tui/crates/acpmux#0.1.0",
               "target": {"kind": ["lib"]},
               "message": {"code": {"code": f"clippy::{lint}"},
                           "spans": [{"is_primary": True, "file_name": "crates/acpmux/src/lib.rs",
                                      "line_start": line, "column_start": 1}]}} for line in range(1, hits + 1)]
    lines.append({"reason": "build-finished", "success": finished})
    return "".join(json.dumps(line) + "\n" for line in lines)


class RatchetAgainstBaseTests(unittest.TestCase):
    """rust_panic_ratchet.py --base-clippy-json: the fast gates' rerun after a baseline row went down
    (#28182 landed six acpmux indexing hits over a row lowered after its own check ran) charges the
    change only for hits the base does not already have."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        here = self.tmp / "scripts/cmux-next"
        here.mkdir(parents=True)
        (here / "rust_panic_ratchet.py").write_text(RATCHET.read_text())
        (self.tmp / "cmux-tui/crates/acpmux/src").mkdir(parents=True)
        lints = ["unwrap_used", "indexing_slicing", "arithmetic_side_effects"]
        (here / "rust-panic-baseline.json").write_text(json.dumps({"crates": {"acpmux": {
            "unwrap_used": 0, "indexing_slicing": 693, "arithmetic_side_effects": 10}}, "lints": lints}))

    def judge(self, head: str, base: str | None = None) -> subprocess.CompletedProcess[str]:
        (self.tmp / "head.jsonl").write_text(head)
        args = ["--repo", str(self.tmp), "--clippy-json", str(self.tmp / "head.jsonl")]
        if base is not None:
            (self.tmp / "base.jsonl").write_text(base)
            args += ["--base-clippy-json", str(self.tmp / "base.jsonl")]
        return subprocess.run([sys.executable, str(self.tmp / "scripts/cmux-next/rust_panic_ratchet.py"), *args],
                              capture_output=True, text=True, cwd=self.tmp)

    def test_hits_over_a_lowered_row_are_the_changes_when_the_base_is_at_its_row(self) -> None:
        # #28182's shape: the tip lowered 699 -> 693 and is at 693; the merge has the PR's six more.
        result = self.judge(clippy_jsonl(699), clippy_jsonl(693))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("acpmux: clippy::indexing_slicing 699 > baseline 693", result.stderr)

    def test_a_base_already_over_its_row_is_the_bases_red(self) -> None:
        result = self.judge(clippy_jsonl(700), clippy_jsonl(700))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("::warning title=rust panic ratchet (base red)::acpmux: clippy::indexing_slicing 700", result.stderr)

    def test_a_hit_added_over_a_red_base_is_the_changes(self) -> None:
        result = self.judge(clippy_jsonl(702), clippy_jsonl(700))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("702 > baseline 693", result.stderr)

    def test_a_base_run_that_did_not_finish_excuses_nothing(self) -> None:
        result = self.judge(clippy_jsonl(700), clippy_jsonl(700, finished=False))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("base clippy run did not finish", result.stderr)

    def test_without_a_base_run_every_count_over_the_row_is_red(self) -> None:
        self.assertEqual(self.judge(clippy_jsonl(700)).returncode, 1)
        self.assertEqual(self.judge(clippy_jsonl(693)).returncode, 0)


if __name__ == "__main__":
    unittest.main()
