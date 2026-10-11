#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for toolchain_notices.py and toolchains.json (stdlib unittest, no
network, no cargo, no zig)."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(HERE))
import toolchain_notices as tn  # noqa: E402

COMMIT_A = "a" * 40
COMMIT_B = "b" * 40


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Fixture:
    """A repo with two rust-toolchain.toml files, two Ghostty manifests and a manifest."""

    def __init__(self, root: Path):
        self.root = root
        self.texts = root / "texts"
        self.files = {
            "rust-1.95.0/COPYRIGHT-library.html": b"<html>rust 1.95.0 library</html>\n",
            "rust-1.88.0/COPYRIGHT-library.html": b"<html>rust 1.88.0 library</html>\n",
            "zig-0.16.0/LICENSE": b"The MIT License (Expat)\n\nCopyright (c) Zig contributors\n",
        }
        for rel, data in self.files.items():
            (self.texts / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.texts / rel).write_bytes(data)
        self.write("cmux-tui/rust-toolchain.toml", '[toolchain]\nchannel = "1.95.0"\nprofile = "minimal"\n')
        self.write("Native/DiffSidecar/rust-toolchain.toml", '[toolchain]\nchannel = "1.88.0"\n')
        self.write("ghostty-next/build.zig.zon", '.{\n    .minimum_zig_version = "0.16.0",\n}\n')
        self.manifest = {
            "bundle_dir": "Contents/Resources/toolchain-licenses",
            "rust": [
                {"version": "1.95.0", "rustc_commit": COMMIT_A, "file": "rust-1.95.0/COPYRIGHT-library.html",
                 "sha256": sha(self.files["rust-1.95.0/COPYRIGHT-library.html"]), "source": "fixture",
                 "toolchain_files": ["cmux-tui/rust-toolchain.toml"], "binaries": "bin/cmux"},
                {"version": "1.88.0", "rustc_commit": COMMIT_B, "file": "rust-1.88.0/COPYRIGHT-library.html",
                 "sha256": sha(self.files["rust-1.88.0/COPYRIGHT-library.html"]), "source": "fixture",
                 "toolchain_files": ["Native/DiffSidecar/rust-toolchain.toml"], "binaries": "bin/cmux-diff-sidecar"},
            ],
            "zig": [
                {"version": "0.16.0", "ci_version": "0.16.0", "file": "zig-0.16.0/LICENSE", "sha256": sha(self.files["zig-0.16.0/LICENSE"]),
                 "source": "fixture", "ghostty_sources": ["ghostty-next"], "binaries": "bin/cmux"},
            ],
        }

    def write(self, rel: str, text: str) -> None:
        (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
        (self.root / rel).write_text(text)

    def load(self) -> "tn.Manifest":
        return tn.Manifest.from_dict(self.manifest, self.texts)


class ToolchainNoticesTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self._tmp.name))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    # Repository ties -----------------------------------------------------------

    def test_a_consistent_repo_has_no_problems(self) -> None:
        self.assertEqual(tn.repo_problems(self.fx.load(), self.fx.root), [])

    def test_a_rust_toolchain_bump_stops_until_reviewed(self) -> None:
        self.fx.write("cmux-tui/rust-toolchain.toml", '[toolchain]\nchannel = "1.96.0"\n')
        [problem] = tn.repo_problems(self.fx.load(), self.fx.root)
        self.assertIn("cmux-tui/rust-toolchain.toml", problem)
        self.assertIn("1.96.0", problem)
        self.assertIn("COPYRIGHT-library.html", problem)

    def test_a_zig_bump_in_ghostty_next_stops_until_reviewed(self) -> None:
        self.fx.write("ghostty-next/build.zig.zon", '.{\n    .minimum_zig_version = "0.17.0",\n}\n')
        [problem] = tn.repo_problems(self.fx.load(), self.fx.root)
        self.assertIn("ghostty-next/build.zig.zon", problem)
        self.assertIn("0.17.0", problem)

    def test_the_exact_ci_zig_version_must_be_recorded_and_match(self) -> None:
        self.fx.manifest["zig"][0]["ci_version"] = "0.16.1"
        [problem] = tn.repo_problems(self.fx.load(), self.fx.root)
        self.assertIn("ci_version", problem)
        self.assertIn("0.16.1", problem)
        del self.fx.manifest["zig"][0]["ci_version"]
        with self.assertRaises(tn.ManifestError):
            self.fx.load()

    def test_a_missing_ghostty_manifest_fails_instead_of_passing(self) -> None:
        (self.fx.root / "ghostty-next/build.zig.zon").unlink()
        [problem] = tn.repo_problems(self.fx.load(), self.fx.root)
        self.assertIn("ghostty-next/build.zig.zon", problem)
        self.assertIn("git submodule update --init ghostty-next", problem)

    def test_the_classic_ghostty_submodule_is_not_read(self) -> None:
        # The Zig minimum comes from ghostty-next only: a checkout without the classic
        # `ghostty` submodule passes, and a different Zig in classic Ghostty is ignored.
        self.assertFalse((self.fx.root / "ghostty").exists())
        self.assertEqual(tn.repo_problems(self.fx.load(), self.fx.root), [])
        self.fx.write("ghostty/build.zig.zon", '.{\n    .minimum_zig_version = "0.15.2",\n}\n')
        self.assertEqual(tn.repo_problems(self.fx.load(), self.fx.root), [])

    def test_a_stored_text_must_match_its_sha256(self) -> None:
        (self.fx.texts / "zig-0.16.0/LICENSE").write_bytes(b"edited\n")
        problems = tn.repo_problems(self.fx.load(), self.fx.root)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("zig-0.16.0/LICENSE", problems[0])
        self.assertIn("sha256", problems[0])

    def test_manifest_rejects_unknown_keys_and_a_bad_commit(self) -> None:
        self.fx.manifest["rust"][0]["extra"] = 1
        with self.assertRaises(tn.ManifestError):
            self.fx.load()
        del self.fx.manifest["rust"][0]["extra"]
        self.fx.manifest["rust"][0]["rustc_commit"] = "abc"
        with self.assertRaises(tn.ManifestError):
            self.fx.load()

    # Bundle -------------------------------------------------------------------

    def app_with(self, binary: bytes) -> Path:
        app = self.fx.root / "x.app"
        (app / "Contents/Resources/bin").mkdir(parents=True, exist_ok=True)
        (app / "Contents/Resources/bin/tool").write_bytes(binary)
        tn.install(self.fx.load(), app / "Contents/Resources")
        return app

    def test_install_copies_every_text_under_the_bundle_dir(self) -> None:
        app = self.app_with(b"")
        bundled = app / "Contents/Resources/toolchain-licenses"
        self.assertEqual(
            sorted(p.relative_to(bundled).as_posix() for p in bundled.rglob("*") if p.is_file()),
            sorted(self.fx.files),
        )
        for rel, data in self.fx.files.items():
            self.assertEqual((bundled / rel).read_bytes(), data)

    def test_install_replaces_an_old_tree(self) -> None:
        stale = self.fx.root / "x.app/Contents/Resources/toolchain-licenses/rust-1.80.0/COPYRIGHT-library.html"
        stale.parent.mkdir(parents=True)
        stale.write_text("old\n")
        self.app_with(b"")
        self.assertFalse(stale.exists())

    def test_install_refuses_a_text_that_does_not_match(self) -> None:
        (self.fx.texts / "rust-1.95.0/COPYRIGHT-library.html").write_bytes(b"edited\n")
        with self.assertRaises(tn.ManifestError):
            tn.install(self.fx.load(), self.fx.root / "out")

    def test_rust_std_follows_the_rustc_commit_inside_the_binary(self) -> None:
        binary = b"\0panicked at /rustc/" + COMMIT_A.encode() + b"/library/core/src/option.rs\0"
        app = self.app_with(binary)
        self.assertEqual(tn.rust_std_problems(self.fx.load(), app, "Contents/Resources/bin/tool"), [])

    def test_rust_std_fails_for_an_unreviewed_toolchain(self) -> None:
        binary = b"/rustc/" + ("c" * 40).encode() + b"/library/std/src/rt.rs"
        app = self.app_with(binary)
        [problem] = tn.rust_std_problems(self.fx.load(), app, "Contents/Resources/bin/tool")
        self.assertIn("c" * 40, problem)
        self.assertIn("toolchains.json", problem)

    def test_rust_std_needs_the_bundled_text_of_every_linked_toolchain(self) -> None:
        binary = b"/rustc/" + COMMIT_A.encode() + b"/library/a.rs\0/rustc/" + COMMIT_B.encode() + b"/library/b.rs"
        app = self.app_with(binary)
        (app / "Contents/Resources/toolchain-licenses/rust-1.88.0/COPYRIGHT-library.html").unlink()
        [problem] = tn.rust_std_problems(self.fx.load(), app, "Contents/Resources/bin/tool")
        self.assertIn("rust-1.88.0/COPYRIGHT-library.html", problem)

    def test_rust_std_fails_when_the_binary_names_no_rustc_commit(self) -> None:
        app = self.app_with(b"no rust here")
        [problem] = tn.rust_std_problems(self.fx.load(), app, "Contents/Resources/bin/tool")
        self.assertIn("/rustc/", problem)

    def test_zig_std_needs_every_reviewed_zig_text(self) -> None:
        app = self.app_with(b"")
        self.assertEqual(tn.zig_std_problems(self.fx.load(), app), [])
        (app / "Contents/Resources/toolchain-licenses/zig-0.16.0/LICENSE").write_bytes(b"edited\n")
        [problem] = tn.zig_std_problems(self.fx.load(), app)
        self.assertIn("zig-0.16.0/LICENSE", problem)

    # The shipped manifest -------------------------------------------------------

    def test_shipped_manifest_loads_and_its_texts_match(self) -> None:
        manifest = tn.load()
        self.assertEqual(tn.text_problems(manifest), [])
        rust = {e.version: e for e in manifest.rust}
        self.assertIn("cmux-tui/rust-toolchain.toml", rust["1.95.0"].toolchain_files)
        self.assertIn("first-party-apps/cloud/server/rust-toolchain.toml", rust["1.95.0"].toolchain_files)
        self.assertIn("Native/DiffSidecar/rust-toolchain.toml", rust["1.98.1"].toolchain_files)
        self.assertEqual(rust["1.95.0"].rustc_commit, "59807616e1fa2540724bfbac14d7976d7e4a3860")
        self.assertEqual(rust["1.95.0"].sha256, "90567e2718bf7fd65a71a3a43c5596488e80e5f51ed02bfea6fec54458b5f3d1")
        [zig] = manifest.zig
        self.assertEqual(zig.version, "0.16.0")
        self.assertEqual(zig.ci_version, "0.16.0")
        self.assertEqual(zig.ghostty_sources, ["ghostty-next"])

    def test_shipped_rust_ties_hold_for_this_checkout(self) -> None:
        # The Zig half needs the Ghostty submodules; CI initializes them.
        manifest = tn.load()
        self.assertEqual(tn.rust_toolchain_problems(manifest, ROOT), [])


if __name__ == "__main__":
    unittest.main()
