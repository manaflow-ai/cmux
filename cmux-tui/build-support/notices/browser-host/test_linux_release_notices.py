#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for linux_release_notices.py (stdlib unittest; no cargo, no network)."""

from __future__ import annotations

import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import linux_release_notices as notices  # noqa: E402

CRATES = "## Rust crates (fixture)\n\n- **rquickjs-sys 0.14.0**: MIT.\n"


def run(argv: list[str]) -> int:
    with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
        return notices.main(argv, crates=lambda cache, tag: CRATES)


class ComposeTest(unittest.TestCase):
    def test_sections(self):
        text = notices.compose(CRATES, notices.load_inputs())
        for needle in (
            "bin/cmux-browser-host",
            "x86_64-unknown-linux-gnu",
            "aarch64-unknown-linux-gnu",
            "GPL-3.0-or-later",
            "## Rust standard library (rustc ",
            "COPYRIGHT-library.html",
            "compiler_rt",
            "musl",
            "glibc",
            "`vendor/acorn.js`",
            "`vendor/playwright-injected.js`",
            "`vendor/playwright-locator-utils.js`",
            "Apache License",
            "Copyright (c) Microsoft Corporation",
            CRATES.strip(),
        ):
            self.assertIn(needle, text)

    def test_source_tag_is_the_release_tag(self):
        self.assertEqual(notices.source_tag(), f"cmux-browser-host-v{notices.crate_version()}")


class CheckTest(unittest.TestCase):
    def test_check_fails_when_stale_and_passes_when_current(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "notices.md"
            out.write_text("stale\n", encoding="utf-8")
            self.assertEqual(run(["--check", "--out", str(out)]), 1)
            self.assertEqual(out.read_text(encoding="utf-8"), "stale\n")
            self.assertEqual(run(["--out", str(out)]), 0)
            self.assertEqual(run(["--check", "--out", str(out)]), 0)

    def test_check_fails_when_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(run(["--check", "--out", str(Path(tmp) / "absent.md")]), 1)


if __name__ == "__main__":
    unittest.main()
