#!/usr/bin/env python3
"""Tests for sync-resource-api.py: one catalog, seven identical SDK descriptors."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import shutil
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("sync-resource-api.py")
SPEC = importlib.util.spec_from_file_location("sync_resource_api", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)

TUI = Path(__file__).resolve().parents[3]
CATALOG = TUI / "spec" / "resource-operations-v2.json"
PACKAGES = ("cpp", "go", "java", "python", "rust", "typescript", "zig")


class SyncResourceApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        (self.root / "spec").mkdir()
        shutil.copy(CATALOG, self.root / "spec" / CATALOG.name)
        for package in PACKAGES:
            (self.root / "bindings" / package).mkdir(parents=True)

    def tearDown(self) -> None:
        self.directory.cleanup()

    def descriptor(self, package: str) -> Path:
        return self.root / "bindings" / package / ".cmux-resource-api.json"

    def run_sync(self, *arguments: str) -> tuple[int, str]:
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            status = SYNC.main(["--root", str(self.root), *arguments])
        return status, errors.getvalue()

    def test_writes_the_same_descriptor_to_all_seven_sdks(self) -> None:
        status, _ = self.run_sync()
        self.assertEqual(status, 0)
        texts = {package: self.descriptor(package).read_text() for package in PACKAGES}
        self.assertEqual(len(set(texts.values())), 1, "every SDK gets the same bytes")
        document = json.loads(texts["zig"])
        catalog = json.loads(CATALOG.read_text())
        self.assertEqual(document["protocol"], catalog["protocol"])
        self.assertEqual(set(document["operations"]), set(catalog["operations"]))

    def test_check_passes_when_all_seven_match_and_writes_nothing(self) -> None:
        self.assertEqual(self.run_sync()[0], 0)
        before = {package: self.descriptor(package).stat().st_mtime_ns for package in PACKAGES}
        status, errors = self.run_sync("--check")
        self.assertEqual(status, 0, errors)
        after = {package: self.descriptor(package).stat().st_mtime_ns for package in PACKAGES}
        self.assertEqual(before, after)

    def test_check_fails_and_names_each_stale_descriptor(self) -> None:
        self.assertEqual(self.run_sync()[0], 0)
        self.descriptor("zig").write_text("{}\n")
        self.descriptor("go").unlink()
        status, errors = self.run_sync("--check")
        self.assertEqual(status, 1)
        self.assertIn("bindings/zig/.cmux-resource-api.json", errors)
        self.assertIn("bindings/go/.cmux-resource-api.json", errors)
        self.assertNotIn("bindings/rust/.cmux-resource-api.json", errors)
        self.assertEqual(self.descriptor("zig").read_text(), "{}\n", "--check never writes")

    def test_a_missing_sdk_directory_fails_instead_of_being_skipped(self) -> None:
        shutil.rmtree(self.root / "bindings" / "java")
        status, errors = self.run_sync()
        self.assertEqual(status, 1)
        self.assertIn("bindings/java", errors)
        self.assertFalse(self.descriptor("rust").exists(), "nothing is written when one SDK is missing")

    def test_the_committed_descriptors_match_the_catalog(self) -> None:
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            status = SYNC.main(["--root", str(TUI), "--check"])
        self.assertEqual(status, 0, errors.getvalue())


if __name__ == "__main__":
    unittest.main()
