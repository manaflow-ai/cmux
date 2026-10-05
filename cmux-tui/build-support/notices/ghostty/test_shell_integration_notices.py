#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Every file of ghostty-next/src/shell-integration that cmux ships (the app bundles the
directory; cmux-tui embeds some with include_str!) has a reviewed notice row.
Stdlib only; no network."""

from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
SPEC = importlib.util.spec_from_file_location("shell_integration_notices", HERE / "shell_integration_notices.py")
assert SPEC and SPEC.loader
si = importlib.util.module_from_spec(SPEC)
sys.modules["shell_integration_notices"] = si
SPEC.loader.exec_module(si)

PREEXEC_HEAD = "# bash-preexec.sh -- Bash support for ZSH-like 'preexec' and 'precmd' functions.\n#\n# V0.7.0\n"
KITTY_HEAD = "# Parts of this script are based on Kitty's bash integration. Kitty is\n# distributed under GPLv3\n"


class RepositoryTest(unittest.TestCase):
    def test_the_manifest_reviews_bash_preexec_0_7_0_with_its_mit_text(self) -> None:
        manifest = si.load()
        row = manifest["files"]["bash/bash-preexec.sh"]
        self.assertEqual(row["license"], "MIT")
        text = si.text(manifest, row["text"])
        self.assertIn("Copyright (c) 2017 Ryan Caloras and contributors", text)
        self.assertIn("0.7.0", row["owner"])
        for path in ("bash/ghostty.bash", "zsh/.zshenv", "zsh/ghostty-integration"):
            self.assertEqual(manifest["files"][path]["license"], "GPL-3.0-or-later", path)

    def test_the_repository_passes_when_the_submodule_objects_are_here(self) -> None:
        git_dir = ROOT / "ghostty-next"
        if not (git_dir / ".git").exists():
            self.skipTest("ghostty-next is not checked out (the notices CI step checks it)")
        self.assertEqual(si.check_repository(ROOT, git_dir), [])

    def test_the_app_notices_and_the_bundle_map_carry_the_section(self) -> None:
        notices = (ROOT / "THIRD_PARTY_LICENSES.md").read_text()
        self.assertIn("<!-- notices-section: manual-ghostty-shell-integration -->", notices)
        self.assertIn("Copyright (c) 2017 Ryan Caloras and contributors", notices)
        entries = json.loads((ROOT / "scripts/cmux-next/notices/bundle-map.json").read_text())
        paths = {e["path"]: e["notices"] for e in entries["entries"] + entries["resources"]}
        for path in ("Contents/Resources/bin/cmux", "Contents/Resources/bin/cmux-tui-ssh/cmux-tui-*", "Contents/Resources/ghostty/shell-integration"):
            self.assertIn("section:manual-ghostty-shell-integration", paths[path], path)


class CheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = copy.deepcopy(si.load())
        self.files = {path: (PREEXEC_HEAD if path.endswith("bash-preexec.sh") else KITTY_HEAD if self.manifest["files"][path]["license"] != "MIT" else "# ghostty\n") for path in self.manifest["files"]}
        self.embedded = {path for path, row in self.manifest["files"].items() if row["embedded"]}
        self.hand = (ROOT / "scripts/cmux-next/notices/hand-written.md").read_text()

    def problems(self) -> list[str]:
        return si.problems(self.manifest, self.files, {("ghostty-next", p) for p in self.embedded}, self.hand)

    def test_the_reviewed_files_pass(self) -> None:
        self.assertEqual(self.problems(), [])

    def test_a_new_file_without_a_row_fails(self) -> None:
        self.files["posix/ghostty.sh"] = "# new\n"
        self.assertTrue(any("posix/ghostty.sh" in p for p in self.problems()))

    def test_a_row_for_a_removed_file_fails(self) -> None:
        del self.files["zsh/.zshenv"]
        self.assertTrue(any("zsh/.zshenv" in p for p in self.problems()))

    def test_another_bash_preexec_version_fails_until_reviewed(self) -> None:
        self.files["bash/bash-preexec.sh"] = PREEXEC_HEAD.replace("V0.7.0", "V0.8.0")
        self.assertTrue(any("bash/bash-preexec.sh" in p for p in self.problems()))

    def test_a_changed_license_text_fails(self) -> None:
        name = self.manifest["files"]["bash/bash-preexec.sh"]["text"]
        self.manifest["texts"][name]["sha256"] = "0" * 64
        self.assertTrue(self.problems())

    def test_an_include_str_without_the_embedded_flag_fails(self) -> None:
        self.embedded.add("elvish/lib/ghostty-integration.elv")
        self.assertTrue(any("elvish" in p for p in self.problems()))

    def test_an_embedded_flag_without_an_include_fails(self) -> None:
        self.embedded.discard("bash/bash-preexec.sh")
        self.assertTrue(any("bash/bash-preexec.sh" in p for p in self.problems()))

    def test_an_include_from_another_ghostty_tree_fails(self) -> None:
        problems = si.problems(self.manifest, self.files, {("ghostty", "bash/ghostty.bash")} | {("ghostty-next", p) for p in self.embedded}, self.hand)
        self.assertTrue(any("ghostty/src/shell-integration" in p for p in problems))

    def test_the_hand_written_section_must_hold_the_text(self) -> None:
        self.hand = self.hand.replace("Ryan Caloras and contributors", "R. Caloras", 1)
        self.assertTrue(self.problems())

    def test_embedded_paths_are_found_in_rust_sources(self) -> None:
        tmp = Path(tempfile.mkdtemp())
        (tmp / "a.rs").write_text('const A: &str = include_str!(\n    "../../../../ghostty-next/src/shell-integration/bash/bash-preexec.sh"\n);\nconst B: &[u8] = include_bytes!("../ghostty/src/shell-integration/zsh/.zshenv");\n')
        self.assertEqual(si.embedded_paths(tmp), {("ghostty-next", "bash/bash-preexec.sh"), ("ghostty", "zsh/.zshenv")})

    def test_the_tree_is_read_from_git_at_the_gitlink(self) -> None:
        tmp = Path(tempfile.mkdtemp())
        run = lambda *a: subprocess.run(["git", "-C", str(tmp), *a], check=True, capture_output=True, text=True).stdout.strip()
        run("init", "-q")
        (tmp / "src/shell-integration/bash").mkdir(parents=True)
        (tmp / "src/shell-integration/bash/x.sh").write_text("x\n")
        run("add", ".")
        run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "t")
        self.assertEqual(si.read_tree(tmp, run("rev-parse", "HEAD")), {"bash/x.sh": "x\n"})


if __name__ == "__main__":
    unittest.main()
