#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for browser_host_js_notices.py (stdlib unittest)."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import browser_host_js_notices as notices  # noqa: E402

LICENSE = "MIT License\r\n\r\nCopyright (c) Example\r\n"


class BrowserHostJsNoticesTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.base = root / "notices"
        (self.base / "texts").mkdir(parents=True)
        (self.base / "texts/LICENSE").write_bytes(LICENSE.encode())
        self.js = root / "js"
        (self.js / "vendor").mkdir(parents=True)
        (self.js / "vendor/lib.js").write_text("// Vendored from lib 1.2.3\nvar x;\n")
        (self.js / "runtime.js").write_text("var own = 1;\n")
        (self.js / "manifest.json").write_text(json.dumps({"repl": ["vendor/lib.js", "runtime.js"]}))
        self.manifest = {
            "texts": {"lib": {"file": "texts/LICENSE", "sha256": hashlib.sha256(LICENSE.encode()).hexdigest()}},
            "files": {"vendor/lib.js": {"texts": ["lib"], "marker": r"^// Vendored from lib 1\.2\.3$"}},
        }
        self.section = "## cmux browser host runtime JavaScript\n\n- `vendor/lib.js`: lib\n\n```text\nMIT License\n\nCopyright (c) Example\n```\n\n## Next\n"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def problems(self) -> list[str]:
        return notices.problems(self.manifest, self.js, self.section, self.base)

    def test_reviewed_tree_passes(self) -> None:
        self.assertEqual(self.problems(), [])

    def test_new_vendor_file_without_a_row_fails(self) -> None:
        (self.js / "vendor/other.js").write_text("x\n")
        [error] = self.problems()
        self.assertIn("js/vendor/other.js is vendored but browser-host-js.json has no row", error)

    def test_new_upstream_version_fails_the_marker(self) -> None:
        (self.js / "vendor/lib.js").write_text("// Vendored from lib 2.0.0\n")
        [error] = self.problems()
        self.assertIn("no longer matches its reviewed marker", error)

    def test_vendor_file_the_manifest_does_not_embed_fails(self) -> None:
        (self.js / "manifest.json").write_text(json.dumps({"repl": ["runtime.js"]}))
        [error] = self.problems()
        self.assertIn("js/manifest.json does not embed it", error)

    def test_stale_row_fails(self) -> None:
        (self.js / "vendor/lib.js").unlink()
        self.assertIn("browser-host-js.json has a row for js/vendor/lib.js, which is gone; remove it", self.problems())

    def test_copied_code_outside_vendor_fails(self) -> None:
        (self.js / "runtime.js").write_text("// Adapted from somewhere 1.0\n")
        [error] = self.problems()
        self.assertIn("js/runtime.js names a third-party origin", error)

    def test_changed_text_and_missing_notice_fail(self) -> None:
        (self.base / "texts/LICENSE").write_text("edited\n")
        [error] = self.problems()
        self.assertIn("sha256 differs", error)
        (self.base / "texts/LICENSE").write_bytes(LICENSE.encode())
        self.section = "## cmux browser host runtime JavaScript\n\nnothing\n"
        errors = self.problems()
        self.assertIn("hand-written.md section 'cmux browser host runtime JavaScript' does not name `vendor/lib.js`", errors)
        self.assertIn("hand-written.md section 'cmux browser host runtime JavaScript' lacks the lib text unchanged (in a text block)", errors)

    def test_repository_passes(self) -> None:
        self.assertEqual(notices.check_repository(), [])


if __name__ == "__main__":
    unittest.main()
