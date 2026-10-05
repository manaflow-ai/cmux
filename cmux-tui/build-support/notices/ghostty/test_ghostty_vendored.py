#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for ghostty_vendored.py and the "vendored" section of
pinned-licenses/MANIFEST.json (stdlib only, no zig, no network)."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ghostty_vendored as vendored  # noqa: E402

MANIFEST = json.loads((HERE / "pinned-licenses/MANIFEST.json").read_text())


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def tree(files: dict[str, bytes]) -> vendored.Tree:
    return vendored.Tree(files, lambda path: files[path])


ZON = b'.{ .name = .x, .dependencies = .{ .upstream = .{ .url = "https://example/u.tgz", .hash = "u-1" } } }\n'


class CheckTreeTest(unittest.TestCase):
    def test_license_file_covers_the_directory(self) -> None:
        problems, _ = vendored.check_tree(tree({"pkg/a/LICENSE": b"MIT", "pkg/a/x.c": b"x"}), {})
        self.assertEqual(problems, [])

    def test_unlisted_directory_fails_with_the_pin_hint(self) -> None:
        problems, _ = vendored.check_tree(tree({"vendor/glad/src/gl.c": b"x"}), {})
        self.assertEqual(len(problems), 1)
        self.assertIn("vendor/glad", problems[0])
        self.assertIn("pinned-licenses/MANIFEST.json", problems[0])

    def test_zig_only_directory_still_needs_an_entry(self) -> None:
        problems, _ = vendored.check_tree(tree({"pkg/z/build.zig": b"x"}), {})
        self.assertEqual(len(problems), 1)
        entry = {"covered_by": "ghostty", "files": {}, "note": "wrapper"}
        self.assertEqual(vendored.check_tree(tree({"pkg/z/build.zig": b"x"}), {"pkg/z": entry})[0], [])

    def test_ghostty_files_are_reviewed_by_content(self) -> None:
        entry = {"covered_by": "ghostty", "files": {"ext.c": sha(b"own")}, "note": "Ghostty's own"}
        self.assertEqual(vendored.check_tree(tree({"pkg/m/ext.c": b"own"}), {"pkg/m": entry})[0], [])
        problems, _ = vendored.check_tree(tree({"pkg/m/ext.c": b"changed"}), {"pkg/m": entry})
        self.assertIn("not a reviewed version", problems[0])
        problems, _ = vendored.check_tree(tree({"pkg/m/ext.c": b"own", "pkg/m/new.c": b"n"}), {"pkg/m": entry})
        self.assertIn("pkg/m/new.c: file not reviewed", problems[0])

    def test_several_reviewed_versions(self) -> None:
        entry = {"covered_by": "ghostty", "files": {"a.h": [sha(b"v1"), sha(b"v2")]}, "note": "two trees"}
        for content in (b"v1", b"v2"):
            self.assertEqual(vendored.check_tree(tree({"pkg/m/a.h": content}), {"pkg/m": entry})[0], [])

    def test_zig_dependency_must_be_declared(self) -> None:
        entry = {"covered_by": "zig-dependency:upstream", "files": {"o.h": sha(b"o")}, "note": "derived"}
        files = {"pkg/d/o.h": b"o", "pkg/d/build.zig.zon": ZON}
        self.assertEqual(vendored.check_tree(tree(files), {"pkg/d": entry})[0], [])
        other = {**entry, "covered_by": "zig-dependency:missing"}
        problems, _ = vendored.check_tree(tree(files), {"pkg/d": other})
        self.assertIn("declares no dependency 'missing'", problems[0])

    def test_pinned_entries_are_returned(self) -> None:
        entry = {"covered_by": "pinned:simdutf", "files": {"vendor/s.h": sha(b"s")}, "note": "simdutf"}
        problems, pinned = vendored.check_tree(tree({"pkg/simdutf/vendor/s.h": b"s"}), {"pkg/simdutf": entry})
        self.assertEqual((problems, pinned), ([], [("pkg/simdutf", "simdutf")]))


class ValidateEntriesTest(unittest.TestCase):
    PACKAGES = {"simdutf": {}}

    def assert_invalid(self, entries: dict) -> None:
        with self.assertRaises(ValueError):
            vendored.validate_entries(entries, self.PACKAGES)

    def test_star_only_for_ghostty(self) -> None:
        vendored.validate_entries({"vendor/fonts": {"covered_by": "ghostty", "files": {"a": "*"}, "note": "too large"}}, self.PACKAGES)
        self.assert_invalid({"pkg/d": {"covered_by": "zig-dependency:u", "files": {"a": "*"}, "note": "n"}})
        self.assert_invalid({"pkg/s": {"covered_by": "pinned:simdutf", "files": {"a": "*"}, "note": "n"}})

    def test_malformed_entries(self) -> None:
        good = {"covered_by": "ghostty", "files": {}, "note": "n"}
        self.assert_invalid({"src/x": good})
        self.assert_invalid({"pkg/x": {**good, "note": " "}})
        self.assert_invalid({"pkg/x": {**good, "covered_by": "not-linked:test"}})
        self.assert_invalid({"pkg/x": {**good, "covered_by": "pinned:unknown"}})
        self.assert_invalid({"pkg/x": {**good, "files": {"a": "abc"}}})


class RepositoryManifestTest(unittest.TestCase):
    def test_manifest_section_is_valid(self) -> None:
        vendored.validate_entries(MANIFEST["vendored"], MANIFEST["packages"])

    def test_known_third_party_directories_ship_pinned_texts(self) -> None:
        expected = {"pkg/simdutf": "pinned:simdutf", "pkg/breakpad": "pinned:lss", "vendor/glad": "pinned:glad",
                    "pkg/freetype": "pinned:fira-code"}
        for key, covered_by in expected.items():
            self.assertEqual(MANIFEST["vendored"][key]["covered_by"], covered_by, key)
        glad = {item["filename"] for item in MANIFEST["packages"]["glad"]["files"]}
        self.assertEqual(glad, {"glad-LICENSE.txt", "glad-khrplatform-NOTICE.txt"})
        self.assertIn("LINKED", MANIFEST["vendored"]["vendor/glad"]["note"])
        simdutf = {item["filename"] for item in MANIFEST["packages"]["simdutf"]["files"]}
        self.assertEqual(simdutf, {"simdutf-LICENSE-APACHE.txt", "simdutf-LICENSE-MIT.txt", "simdutf-isadetection-PyTorch-NOTICE.txt"})

    def test_every_file_has_a_digest(self) -> None:
        # The coordinator's rule: "*" needs a written reason; today no entry uses it.
        for key, entry in MANIFEST["vendored"].items():
            for name, digests in entry["files"].items():
                self.assertNotEqual(digests, "*", f"{key}/{name}")

    def test_reviewed_trees(self) -> None:
        """Optional: CMUX_GHOSTTY_VENDORED_TREES="<git dir>@<rev> ..." checks
        real Ghostty trees (the reviewed ones are in the "vendored" notes)."""
        specs = os.environ.get("CMUX_GHOSTTY_VENDORED_TREES", "").split()
        if not specs:
            self.skipTest("CMUX_GHOSTTY_VENDORED_TREES is not set")
        for spec in specs:
            git_dir, _, rev = spec.rpartition("@")
            result = subprocess.run(
                [sys.executable, str(HERE / "ghostty_vendored.py"), "--git-dir", git_dir, "--rev", rev],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, f"{spec}: {result.stderr}")


class CliTest(unittest.TestCase):
    def test_source_mode(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "pkg/x").mkdir(parents=True)
            (root / "pkg/x/x.c").write_text("x\n")
            result = subprocess.run(
                [sys.executable, str(HERE / "ghostty_vendored.py"), "--source", str(root)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("pkg/x", result.stderr)


if __name__ == "__main__":
    unittest.main()
