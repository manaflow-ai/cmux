#!/usr/bin/env python3
"""A source cache kept between runs (nightly-next's trusted worker) recovers from
an interrupted git checkout and never serves another revision with the same
seven-character prefix."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fetch_crates


def git(*args: str) -> str:
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", *args],
                          check=True, capture_output=True, text=True).stdout.strip()


class FetchGitKeptCache(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.repo = self.root / "dep"
        git("init", "-q", str(self.repo))
        (self.repo / "LICENSE").write_text("one\n")
        git("-C", str(self.repo), "add", "-A")
        git("-C", str(self.repo), "commit", "-q", "-m", "one")
        git("-C", str(self.repo), "config", "uploadpack.allowReachableSHA1InWant", "true")
        self.rev = git("-C", str(self.repo), "rev-parse", "HEAD")
        self.source = f"git+file://{self.repo}#{self.rev}"
        self.cache = self.root / "cache"

    def test_interrupted_checkout_is_started_over(self):
        dest, _, _ = fetch_crates.git_dir(self.cache, self.source)
        partial = dest.with_name(dest.name + ".partial")
        (partial / ".git").mkdir(parents=True)
        (partial / ".git/index.lock").write_text("")
        fetch_crates.fetch_git(self.cache, self.source)
        self.assertEqual((dest / "LICENSE").read_text(), "one\n")
        self.assertFalse(partial.exists())

    def test_a_kept_checkout_of_another_revision_is_replaced(self):
        dest, _, _ = fetch_crates.git_dir(self.cache, self.source)
        dest.mkdir(parents=True)
        git("init", "-q", str(dest))
        (dest / "LICENSE").write_text("other\n")
        git("-C", str(dest), "add", "-A")
        git("-C", str(dest), "commit", "-q", "-m", "other")
        fetch_crates.fetch_git(self.cache, self.source)
        self.assertEqual(git("-C", str(dest), "rev-parse", "HEAD"), self.rev)
        self.assertEqual((dest / "LICENSE").read_text(), "one\n")


if __name__ == "__main__":
    unittest.main()
