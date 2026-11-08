#!/usr/bin/env python3
"""Behavior tests for cmux-tui-spec-changed.py, the router of cmux-tui-spec.yml's pull requests.

On 2026-11-04 #35133 and #35149 merged into feat-cmux-next with `clippy (changed cmux-tui
packages)` red: the branch required no check. It requires that check now, and a required check
must report on every pull request, so the workflow runs on each one and this script says whether
the change touches one of the workflow's own `push` paths (the jobs run) or none (they are
skipped, which GitHub counts as passing). These tests run it on a scratch repository.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("cmux-tui-spec-changed.py")
WORKFLOW = """name: test
on:
  push:
    branches:
      - feat-cmux-next
    paths:
      - "cmux-tui/**"
      # a comment between globs
      - ".github/workflows/cmux-tui-spec.yml"
      - "skills/cmux-browser/**"
      - "docs/remote-agents-and-cloud.md"
      - "skills/*/SKILL.md"
  pull_request:
  workflow_dispatch:
jobs: {}
"""


def git(cwd: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *args],
        cwd=cwd, capture_output=True, text=True, check=True)
    return result.stdout.strip()


class Router(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q")
        workflow = self.repo / ".github/workflows/cmux-tui-spec.yml"
        workflow.parent.mkdir(parents=True)
        workflow.write_text(WORKFLOW)
        (self.repo / "README.md").write_text("base\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def change(self, files: dict[str, str]) -> str:
        for name, text in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "change")
        return git(self.repo, "rev-parse", "HEAD")

    def route(self, *args: str) -> tuple[int, str, str]:
        output = self.repo / "github-output"
        output.write_text("")
        env = dict(os.environ, GITHUB_OUTPUT=str(output))
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--repo", str(self.repo),
             "--workflow", ".github/workflows/cmux-tui-spec.yml", *args],
            capture_output=True, text=True, env=env, check=False)
        return result.returncode, output.read_text(), result.stdout + result.stderr

    def test_a_change_outside_the_paths_skips_the_jobs(self) -> None:
        head = self.change({"README.md": "docs\n", "webviews/src/app.tsx": "x\n", "skills/cmux-browser": "f\n"})
        code, out, log = self.route("--base", self.base, "--head", head)
        self.assertEqual(code, 0, log)
        self.assertEqual(out, "run=false\n")

    def test_a_change_to_any_path_glob_runs_the_jobs(self) -> None:
        for name in ("cmux-tui/crates/acpmux/src/lib.rs", ".github/workflows/cmux-tui-spec.yml",
                     "skills/cmux-browser/references/x.md", "docs/remote-agents-and-cloud.md",
                     "skills/cmux/SKILL.md"):
            with self.subTest(name=name):
                text = WORKFLOW + "# edited\n" if name.endswith("cmux-tui-spec.yml") else f"{name}\n"
                head = self.change({name: text})
                code, out, log = self.route("--base", self.base, "--head", head)
                self.assertEqual(code, 0, log)
                self.assertEqual(out, "run=true\n")

    def test_a_single_star_does_not_cross_a_folder(self) -> None:
        head = self.change({"skills/cmux/extra/SKILL.md": "x\n"})
        self.assertEqual(self.route("--base", self.base, "--head", head)[1], "run=false\n")

    def test_a_deleted_file_on_a_path_runs_the_jobs(self) -> None:
        self.change({"cmux-tui/Cargo.toml": "x\n"})
        base = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "rm", "-q", "cmux-tui/Cargo.toml")
        git(self.repo, "commit", "-qm", "delete")
        head = git(self.repo, "rev-parse", "HEAD")
        self.assertEqual(self.route("--base", base, "--head", head)[1], "run=true\n")

    def test_no_base_runs_the_jobs(self) -> None:
        # A push or a dispatch (no pull request base), or a base the checkout lacks: run, never skip.
        head = self.change({"README.md": "docs\n"})
        self.assertEqual(self.route("--base", "", "--head", head)[1], "run=true\n")
        self.assertEqual(self.route("--base", "0" * 40, "--head", head)[1], "run=true\n")
        code, out, _ = self.route("--base", "1" * 40, "--head", head)
        self.assertEqual((code, out), (0, "run=true\n"))

    def test_a_workflow_without_push_paths_fails_loudly(self) -> None:
        workflow = self.repo / ".github/workflows/cmux-tui-spec.yml"
        workflow.write_text(WORKFLOW.replace("    paths:\n", "    no-paths:\n"))
        head = self.change({"README.md": "docs\n"})
        code, out, log = self.route("--base", self.base, "--head", head)
        self.assertNotEqual(code, 0)
        self.assertIn("push paths", log)
        self.assertEqual(out, "")


if __name__ == "__main__":
    unittest.main()
