from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "verify_go_module_source.py"
SPEC = importlib.util.spec_from_file_location("verify_go_module_source", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
verifier = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = verifier
SPEC.loader.exec_module(verifier)


class VerifyGoModuleSourceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        self.repository = self.root / "repository"
        self.module = self.repository / "nested" / "module"
        self.downloaded = self.root / "downloaded"
        (self.module / "raw").mkdir(parents=True)
        self.downloaded.mkdir()
        self.files = {
            "go.mod": b"module example.com/cmux\n\ngo 1.22\n",
            "client.go": b"package cmux\n",
            "raw/client.go": b"package raw\n",
        }
        (self.repository / "LICENSE").write_bytes(b"release license\n")
        for name, contents in self.files.items():
            path = self.module / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
        self.git("init", "-b", "main")
        self.git("config", "user.email", "release@example.com")
        self.git("config", "user.name", "Release Test")
        self.git("add", ".")
        self.git("commit", "-m", "source")
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()
        for name, contents in self.files.items():
            path = self.downloaded / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
        shutil.copyfile(self.repository / "LICENSE", self.downloaded / "LICENSE")

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.repository,
            check=True,
            capture_output=True,
            text=True,
        )

    def verify(self) -> tuple[str, int]:
        return verifier.verify(
            self.repository,
            self.commit,
            "nested/module",
            self.downloaded,
        )

    def test_accepts_exact_module_tree_and_inherited_root_license(self) -> None:
        digest, file_count = self.verify()

        self.assertEqual(len(digest), 64)
        self.assertEqual(file_count, len(self.files) + 1)

    def test_ignores_untracked_checkout_files(self) -> None:
        (self.module / "untracked.txt").write_text("not released", encoding="utf-8")

        self.verify()

    def test_rejects_changed_public_file(self) -> None:
        (self.downloaded / "client.go").write_text("package stale\n", encoding="utf-8")

        with self.assertRaisesRegex(verifier.VerificationError, "changed: client.go"):
            self.verify()

    def test_rejects_missing_and_unexpected_public_files(self) -> None:
        (self.downloaded / "LICENSE").unlink()
        (self.downloaded / "extra.go").write_text("package extra\n", encoding="utf-8")

        with self.assertRaisesRegex(
            verifier.VerificationError, "missing: LICENSE"
        ) as error:
            self.verify()
        self.assertIn("unexpected: extra.go", str(error.exception))


if __name__ == "__main__":
    unittest.main()
