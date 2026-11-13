#!/usr/bin/env python3
"""Behavior tests for the every-Cargo-workspace PR check (rust-workspaces.py).

Workspaces beside cmux-tui's (optchat-chief, the FFI and host crates with a
[workspace] of their own, the cloud server, ...) had no PR clippy or tests.
These tests drive the list check, the planner and the runner on a scratch
repository with a fake cargo that records its calls.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("rust-workspaces.py")
FAKE_CARGO = """#!/usr/bin/env bash
printf '%s|%s\\n' "$PWD" "$*" >> "$CARGO_LOG"
[[ "$1" == "${FAIL_SUBCOMMAND:-none}" ]] && exit 101
exit 0
"""
LIST = """
[[workspace]]
root = "ws"
covered_by = ".github/workflows/ws.yml"

[[workspace]]
root = "ws/crates/own"
run = true

[[workspace]]
root = "solo"
run = true
args = ["--features", "x"]

[[workspace]]
root = "ws/vendor/up"
skip = "vendored"

[[workspace]]
root = "term"
run = true

[[workspace]]
root = "vws"
run = true
inputs = ["docs/vws-protocol.json"]

[[workspace]]
root = "solo/tool"
run = true

[[workspace]]
root = "vws/side"
run = true
"""


class RustWorkspacesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / "repo"
        # ws: a workspace whose members inherit path dependencies from it.
        self.write("ws/Cargo.toml", '[workspace]\nmembers = ["crates/*"]\nexclude = ["crates/own", "vendor/up"]\n\n'
                   '[workspace.dependencies]\na = { path = "crates/a" }\nc = { path = "crates/c" }\n')
        self.write("ws/crates/a/Cargo.toml", '[package]\nname = "a"\n')
        self.write("ws/crates/a/src/lib.rs", "pub fn a() {}\n")
        self.write("ws/crates/b/Cargo.toml", '[package]\nname = "b"\n\n[dependencies]\na = { workspace = true }\n\n'
                   '[dev-dependencies]\nc = { workspace = true }\n')
        self.write("ws/crates/b/src/lib.rs", "pub fn b() {}\n")
        self.write("ws/crates/c/Cargo.toml", '[package]\nname = "c"\n')
        self.write("ws/crates/c/src/lib.rs", "pub fn c() {}\n")
        # own: a crate inside ws's tree with a workspace of its own, using a by path.
        self.write("ws/crates/own/Cargo.toml", '[package]\nname = "own"\n\n[workspace]\n\n[dependencies]\na = { path = "../a" }\n')
        self.write("ws/crates/own/src/lib.rs", "pub fn own() {}\n")
        self.write("ws/crates/own/Cargo.lock", "# lock\n")
        # up: excluded from ws without a [workspace] of its own, so it is one.
        self.write("ws/vendor/up/Cargo.toml", '[package]\nname = "up"\n')
        # solo: a package outside every workspace, using b (and through it a).
        self.write("solo/Cargo.toml", '[package]\nname = "solo"\n\n[target.\'cfg(unix)\'.dependencies]\nb = { path = "../ws/crates/b" }\n')
        # solo embeds a schema and a skill file, and a sibling's file through concat!.
        self.write("solo/src/main.rs", 'const S: &str = include_str!("../../schemas/s.json");\n'
                   'const K: &str = include_str!("../skills/k/SKILL.md");\n'
                   'const P: &str = include_str!(concat!("../../proto/v1_", "x.json"));\nfn main() {}\n')
        self.write("solo/skills/k/SKILL.md", "---\nname: k\n---\n")
        self.write("solo/README.md", "solo\n")
        self.write("schemas/s.json", "{}\n")
        self.write("proto/v1_x.json", "{}\n")
        # own's tests read fixtures from the tree through CARGO_MANIFEST_DIR.
        self.write("ws/crates/own/tests/t.rs", 'let dir = Path::new(env!("CARGO_MANIFEST_DIR"))\n    .join("../../../fixtures");\n')
        self.write("fixtures/f.json", "{}\n")
        # term's build script reads a token file through a const; its tests name a
        # "../" path that does not exist, which must not count.
        self.write("term/build.rs", 'const TOKENS: &str = "../tokens/t.json";\nconst NOPE: &str = "../escape";\nfn main() {}\n')
        self.write("tokens/t.json", "{}\n")
        # vws: a virtual workspace (no [package] at its root) with a lockfile and toolchain pin.
        self.write("vws/Cargo.toml", '[workspace]\nmembers = ["m"]\nexclude = ["side"]\n')
        # Inside run entries' trees but workspaces of their own: solo/tool has a [workspace] (as
        # cmux-tui/crates/cmux-app-ffi does inside cmux-tui), vws/side is in vws's `exclude`.
        self.write("solo/tool/Cargo.toml", '[package]\nname = "tool"\n\n[workspace]\n')
        self.write("solo/tool/src/lib.rs", 'const T: &str = include_str!("../../../tokens/t.json");\n')
        self.write("vws/side/Cargo.toml", '[package]\nname = "side"\n')
        self.write("vws/side/src/lib.rs", "pub fn side() {}\n")
        self.write("vws/Cargo.lock", "# lock\n")
        self.write("vws/rust-toolchain.toml", '[toolchain]\nchannel = "1.91.0"\n')
        self.write("vws/m/Cargo.toml", '[package]\nname = "m"\n')
        self.write("docs/vws-protocol.json", "{}\n")
        self.write("docs/other.md", "other\n")
        # term: uses the ghostty-vt-sys crate.
        self.write("term/Cargo.toml", '[package]\nname = "term"\n\n[dependencies]\nghostty-vt-sys = { path = "../gvs" }\n')
        self.write("gvs/Cargo.toml", '[package]\nname = "ghostty-vt-sys"\n\n[workspace]\n')
        self.write(".github/workflows/ws.yml", "# lints ws\n")
        self.write(".github/rust-workspaces.toml", LIST + '\n[[workspace]]\nroot = "gvs"\nskip = "test"\n')
        self.git("init", "-q")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.base = self.head()
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "cargo").write_text(FAKE_CARGO)
        (bin_dir / "cargo").chmod(0o755)
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

    def head(self) -> str:
        return self.git("rev-parse", "HEAD").strip()

    def change(self, path: str, text: str = "// changed\n") -> None:
        self.write(path, text)
        self.git("add", "-A")
        self.git("commit", "-qm", "change")

    def script(self, *args: str, env: dict | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(SCRIPT), *args, "--repo", str(self.repo)],
                              env=env or self.env, capture_output=True, text=True)

    def planned(self, base: str | None = None) -> list[str]:
        result = self.script("plan", "--base", self.base if base is None else base)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [job["root"] for job in json.loads(result.stdout)]

    # check

    def test_a_list_naming_every_workspace_passes(self) -> None:
        result = self.script("check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_new_workspace_without_an_entry_fails_the_check(self) -> None:
        self.change("tools/new/Cargo.toml", '[package]\nname = "new"\n')
        result = self.script("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("tools/new is a Cargo workspace with no entry", result.stdout)

    def test_an_entry_that_is_not_a_workspace_fails_the_check(self) -> None:
        self.change(".github/rust-workspaces.toml", LIST + '\n[[workspace]]\nroot = "gvs"\nskip = "t"\n'
                    '\n[[workspace]]\nroot = "ws/crates/a"\nrun = true\n')
        result = self.script("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("'ws/crates/a' in .github/rust-workspaces.toml is not a Cargo workspace root", result.stdout)

    def test_a_covered_by_workflow_must_name_the_root(self) -> None:
        self.change(".github/workflows/ws.yml", "# lints something else\n")
        result = self.script("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("ws: .github/workflows/ws.yml does not exist or does not name ws", result.stdout)

    def test_an_entry_needs_exactly_one_way_of_being_checked(self) -> None:
        self.change(".github/rust-workspaces.toml", LIST.replace('args = ["--features", "x"]', 'skip = "both"')
                    + '\n[[workspace]]\nroot = "gvs"\nskip = "t"\n')
        result = self.script("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("solo needs exactly one of", result.stdout)

    # plan

    def test_a_change_plans_every_workspace_using_it_by_path(self) -> None:
        # own uses a directly; solo uses b, which uses a (inherited from ws's manifest).
        self.change("ws/crates/a/src/lib.rs")
        self.assertEqual(self.planned(), ["ws/crates/own", "solo"])

    def test_a_path_dependency_manifest_change_plans_its_consumers(self) -> None:
        # Cargo metadata changes can invalidate a consumer's standalone lockfile
        # even when the dependency source itself is untouched.
        self.change("ws/crates/a/Cargo.toml", '[package]\nname = "a"\n\n[dependencies]\nserde = "1"\n')
        self.assertEqual(self.planned(), ["ws/crates/own", "solo"])

    def test_a_dev_dependency_of_a_dependency_does_not_reach_further(self) -> None:
        # b's tests use c, but solo only builds b's library.
        self.change("ws/crates/c/src/lib.rs")
        self.assertEqual(self.planned(), [])

    def test_a_change_inside_a_workspace_plans_only_it(self) -> None:
        self.change("solo/src/main.rs")
        self.assertEqual(self.planned(), ["solo"])

    def test_the_manifest_a_dependency_inherits_from_plans_its_users(self) -> None:
        self.change("ws/Cargo.toml", '[workspace]\nmembers = ["crates/*"]\nexclude = ["crates/own", "vendor/up"]\n\n'
                    '[workspace.dependencies]\na = { path = "crates/a", features = ["f"] }\nc = { path = "crates/c" }\n')
        # Both reach ws's members (own through a, solo through b and a).
        self.assertEqual(self.planned(), ["ws/crates/own", "solo"])

    def test_a_file_outside_every_workspace_and_its_reads_plans_nothing(self) -> None:
        self.change("docs/other.md", "more\n")
        self.assertEqual(self.planned(), [])

    def test_any_file_in_a_workspace_plans_it_markdown_too(self) -> None:
        # A skill file is code here (include_str!), so no suffix is ignored.
        self.change("solo/skills/k/SKILL.md", "---\nname: broken\n")
        self.assertEqual(self.planned(), ["solo"])

    def test_a_virtual_workspaces_lockfile_or_toolchain_pin_plans_it(self) -> None:
        for path in ("vws/Cargo.lock", "vws/rust-toolchain.toml"):
            with self.subTest(path=path):
                self.base = self.head()
                self.change(path, "# bumped\n")
                self.assertEqual(self.planned(), ["vws"])

    def test_files_read_from_elsewhere_in_the_tree_plan_their_readers(self) -> None:
        cases = {
            "schemas/s.json": ["solo"],          # include_str! relative to the source file
            "proto/v1_y.json": ["solo"],         # a concat! prefix: its directory
            "fixtures/f.json": ["ws/crates/own"],  # CARGO_MANIFEST_DIR joined with a path
            "docs/vws-protocol.json": ["vws"],   # the entry's inputs
            "tokens/t.json": ["term", "solo/tool"],  # a "../" const naming a tracked file; include_str!
        }
        for path, planned in cases.items():
            with self.subTest(path=path):
                self.base = self.head()
                self.change(path, "{\"v\": 2}\n")
                self.assertEqual(self.planned(), planned)

    def test_no_usable_base_or_a_list_change_plans_every_run_entry(self) -> None:
        everything = ["ws/crates/own", "solo", "term", "vws", "solo/tool", "vws/side"]
        for base in ("", "0" * 40, "f" * 40):
            with self.subTest(base=base):
                self.assertEqual(self.planned(base), everything)
        self.change(".github/rust-workspaces.toml", LIST + '\n[[workspace]]\nroot = "gvs"\nskip = "changed"\n')
        self.assertEqual(self.planned(), everything)

    def test_a_path_inherited_two_hops_away_plans_its_users(self) -> None:
        """solo uses b, b inherits a from ws, and a inherits `far` from ws's [workspace.dependencies], a path outside
        ws's tree: a change to far is solo's (the cmux#41767 review's class: `{ workspace = true }` resolved through
        the dependency's own workspace, not the user's)."""
        self.write("ws/Cargo.toml", (self.repo / "ws/Cargo.toml").read_text() + 'far = { path = "../far" }\n')
        self.write("ws/crates/a/Cargo.toml", '[package]\nname = "a"\n\n[dependencies]\nfar = { workspace = true }\n')
        self.write("far/Cargo.toml", '[package]\nname = "far"\n\n[workspace]\n')
        self.write("far/src/lib.rs", "pub fn far() {}\n")
        self.git("add", ".")
        self.git("commit", "-qm", "far")
        for path in ("far/src/lib.rs", "far/Cargo.toml"):
            with self.subTest(path=path):
                self.base = self.head()
                self.change(path, (self.repo / path).read_text() + ("\n# changed\n" if path.endswith(".toml")
                                                                     else "// changed\n"))
                planned = self.planned()
                self.assertIn("solo", planned)
                self.assertIn("ws/crates/own", planned)

    def test_a_patched_crates_own_paths_plan_the_workspace_that_patches_it(self) -> None:
        """vws patches pz by path (as cmux-next-ios/rust patches smoltcp), and pz inherits q from its own
        workspace's [workspace.dependencies]: a change to q is vws's, like one to pz."""
        self.write("vws/Cargo.toml", (self.repo / "vws/Cargo.toml").read_text()
                   + '\n[patch.crates-io]\npz = { path = "../pz" }\n')
        self.write("pz/Cargo.toml", '[package]\nname = "pz"\n\n[workspace]\n\n[workspace.dependencies]\n'
                   'q = { path = "../q" }\n\n[dependencies]\nq = { workspace = true }\n')
        self.write("q/Cargo.toml", '[package]\nname = "q"\n\n[workspace]\n')
        self.write("q/src/lib.rs", "pub fn q() {}\n")
        self.git("add", ".")
        self.git("commit", "-qm", "patch")
        for path in ("q/src/lib.rs", "q/Cargo.toml", "pz/Cargo.toml"):
            with self.subTest(path=path):
                self.base = self.head()
                self.change(path, (self.repo / path).read_text() + ("\n# changed\n" if path.endswith(".toml")
                                                                     else "// changed\n"))
                self.assertIn("vws", self.planned())

    def test_a_file_read_from_inside_a_nested_workspace_plans_its_reader(self) -> None:
        """solo include_str!s a file inside solo/tool, a workspace of its own under solo's tree: a change to that file
        is solo's too, since an explicit file read crosses the nested boundary (cmux#41767 review F2: read_paths
        dropped it as lexically under solo, and owns() then gave the change to solo/tool alone)."""
        self.write("solo/src/main.rs", (self.repo / "solo/src/main.rs").read_text()
                   + 'const D: &str = include_str!("../tool/data.txt");\n')
        self.write("solo/tool/data.txt", "data\n")
        self.git("add", ".")
        self.git("commit", "-qm", "read")
        self.base = self.head()
        self.change("solo/tool/data.txt", "changed\n")
        planned = self.planned()
        self.assertIn("solo", planned)
        self.assertIn("solo/tool", planned)

    def test_a_change_in_a_nested_workspace_plans_only_it(self) -> None:
        """A Cargo.toml below a workspace with a [workspace] of its own, or in its `exclude`, is another workspace:
        a change there is not the outer one's (the cmux#41742 review's F1 class)."""
        cases = {
            "solo/tool/src/lib.rs": ["solo/tool"],
            "solo/tool/Cargo.toml": ["solo/tool"],
            "vws/side/src/lib.rs": ["vws/side"],
            "vws/side/Cargo.toml": ["vws/side"],
        }
        for path, planned in cases.items():
            with self.subTest(path=path):
                self.base = self.head()
                self.change(path, (self.repo / path).read_text() + ("\n# changed\n" if path.endswith(".toml")
                                                                     else "// changed\n"))
                self.assertEqual(self.planned(), planned)

    def test_a_member_beside_the_root_plans_the_root(self) -> None:
        # As cmux-app-ffi's workspace takes in ../cmux-rd-ffi: a member named with "../" and no path dependency on it.
        self.write("sib/root/Cargo.toml", '[package]\nname = "root"\n\n[workspace]\nmembers = ["../mem"]\n')
        self.write("sib/mem/Cargo.toml", '[package]\nname = "mem"\nworkspace = "../root"\n')
        self.write("sib/mem/src/lib.rs", "pub fn mem() {}\n")
        self.write(".github/rust-workspaces.toml", (self.repo / ".github/rust-workspaces.toml").read_text()
                   + '\n[[workspace]]\nroot = "sib/root"\nrun = true\n')
        self.git("add", ".")
        self.git("commit", "-qm", "sibling member")
        self.base = self.head()
        self.change("sib/mem/src/lib.rs")
        self.assertEqual(self.planned(), ["sib/root"])
        self.assertEqual(self.script("check").returncode, 0)

    def test_a_member_beside_the_root_inherits_its_path_dependencies(self) -> None:
        # cmux#42082 review F1: mem sits under ws's tree, but names sib/root as its workspace; its
        # `{ workspace = true }` dependency resolves from sib/root's [workspace.dependencies], not ws's.
        self.write("sib/root/Cargo.toml", '[package]\nname = "root"\n\n[workspace]\nmembers = ["../../ws/crates/mem"]\n\n'
                   '[workspace.dependencies]\nlib = { path = "../lib" }\n')
        self.write("sib/lib/Cargo.toml", '[package]\nname = "lib"\n\n[workspace]\n')
        self.write("sib/lib/src/lib.rs", "pub fn lib() {}\n")
        self.write("ws/crates/mem/Cargo.toml", '[package]\nname = "mem"\nworkspace = "../../../sib/root"\n\n'
                   '[dependencies]\nlib = { workspace = true }\n')
        self.write(".github/rust-workspaces.toml", (self.repo / ".github/rust-workspaces.toml").read_text()
                   + '\n[[workspace]]\nroot = "sib/root"\nrun = true\n\n[[workspace]]\nroot = "sib/lib"\nskip = "test"\n')
        self.git("add", ".")
        self.git("commit", "-qm", "inherited path")
        self.base = self.head()
        self.change("sib/lib/src/lib.rs")
        self.assertIn("sib/root", self.planned())

    def test_a_nested_workspaces_reads_are_not_the_outer_ones(self) -> None:
        # solo/tool's source reads tokens/t.json; solo does not.
        self.change("tokens/t.json", "{\"v\": 3}\n")
        self.assertNotIn("solo", self.planned())

    def test_a_workspace_using_ghostty_vt_sys_is_planned_with_ghostty(self) -> None:
        self.change("gvs/src/lib.rs")
        result = self.script("plan", "--base", self.base)
        self.assertEqual(json.loads(result.stdout), [{"root": "term", "ghostty": True, "apt": ""}])

    # run

    def calls(self) -> list[tuple[str, str]]:
        lines = self.log.read_text().splitlines() if self.log.exists() else []
        return [(Path(cwd).name, args) for cwd, args in (line.split("|", 1) for line in lines)]

    def test_run_lints_every_target_then_tests_in_the_workspace(self) -> None:
        result = self.script("run", "solo")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [
            ("solo", "clippy --workspace --all-targets --features x -- -D warnings"),
            ("solo", "test --workspace --features x"),
        ])

    def test_run_is_locked_when_the_workspace_tracks_a_lockfile(self) -> None:
        result = self.script("run", "ws/crates/own")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [
            ("own", "clippy --locked --workspace --all-targets -- -D warnings"),
            ("own", "test --locked --workspace"),
        ])

    def test_a_clippy_red_still_runs_the_tests_and_fails(self) -> None:
        result = self.script("run", "solo", env={**self.env, "FAIL_SUBCOMMAND": "clippy"})
        self.assertEqual(result.returncode, 1)
        self.assertEqual([args.split()[0] for _, args in self.calls()], ["clippy", "test"])
        self.assertIn("::error title=solo clippy::", result.stdout)
        self.assertIn("solo: red (clippy)", result.stdout)

    def test_run_refuses_a_root_that_is_not_a_run_entry(self) -> None:
        result = self.script("run", "ws")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
