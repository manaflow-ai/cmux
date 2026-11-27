#!/usr/bin/env python3
"""Tests for select_flows.py and the manifest. Run: python3 -I cmux-next-ios/FlowSuite/test_select_flows.py"""
import json
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
import importlib.util  # noqa: E402

spec = importlib.util.spec_from_file_location("select_flows", HERE / "select_flows.py")
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)
MANIFEST = json.loads((HERE / "flows.json").read_text())


class ManifestTests(unittest.TestCase):
    def test_manifest_matches_the_tree(self):
        self.assertEqual(fs.check(MANIFEST), [])

    def test_every_regression_row_has_a_flow(self):
        rows = {s for f in MANIFEST["flows"] for s in f["source"]}
        for n in range(1, 13):
            self.assertIn(f"regression:{n}", rows)


class SelectTests(unittest.TestCase):
    def sel(self, *paths):
        return fs.select(MANIFEST, list(paths))

    def test_unrelated_change_runs_nothing(self):
        r = self.sel("webviews/src/App.tsx", "docs/readme.md")
        self.assertFalse(r["ios"])
        self.assertEqual(r["flows"], [])
        self.assertEqual(fs.sim_args(r, 2), [])

    def test_ios_docs_only_runs_nothing(self):
        self.assertFalse(self.sel("cmux-next-ios/CLAUDE.md", "cmux-next-ios/verify/x/report.json")["ios"])

    def test_terminal_change_runs_its_flows_plus_smoke_and_compile(self):
        r = self.sel("cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTerminal/KeyRow.swift")
        self.assertTrue(r["compile"])
        for f in ("smoke-launch-sign-in", "compile-app-and-tests", "terminal-key-row-layout",
                  "terminal-composer-bar", "terminal-first-attach"):
            self.assertIn(f, r["flows"])
        self.assertNotIn("chat-mac-look", r["flows"])
        self.assertIn("TerminalKeyRowOnDemandUITests", r["ui"])
        self.assertTrue(r["build_for_testing"])

    def test_ios_file_matching_no_flow_runs_smoke_and_compile_only(self):
        r = self.sel("cmux-next-ios/UITests/Support/Launch.swift")
        self.assertEqual(r["flows"], ["smoke-launch-sign-in", "compile-app-and-tests"])

    def test_any_kit_source_also_builds_the_macos_half(self):
        # Row 17: a macOS-only compile break in the kit hid its chat and model tests for days.
        r = self.sel("cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileVoice/Recorder.swift")
        self.assertEqual(r["flows"], ["smoke-launch-sign-in", "compile-app-and-tests", "kit-macos-swift-test"])

    def test_shared_rust_crate_the_app_links_is_ios_affecting(self):
        r = self.sel("cmux-tui/crates/cmux-tailnet/src/lib.rs")
        self.assertTrue(r["compile"])
        self.assertIn("workspaces-empty-mac-loads", r["flows"])

    def test_shared_swift_package_the_app_links_is_ios_affecting(self):
        r = self.sel("Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/AuthCoordinator.swift")
        self.assertTrue(r["compile"])
        self.assertIn("launch-session-restore", r["flows"])

    def test_mac_pairing_change_selects_the_identity_flow_without_compile(self):
        r = self.sel("Packages/macOS/CmuxNext/Sources/CmuxNextMobileHost/Pairing.swift")
        self.assertTrue(r["ios"])
        self.assertIn("pairing-mac-identity", r["flows"])
        self.assertEqual(r["swift"], [{"package": "Packages/macOS/CmuxNext", "filter": "MobileHostMacIdentityKeychainTests"}])

    def test_sim_args_shards_split_suites(self):
        r = self.sel("cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTerminal/KeyRow.swift")
        lines = fs.sim_args(r, 2)
        self.assertEqual(len(lines), 2)
        joined = " ".join(lines)
        for suite in r["ui"]:
            self.assertIn(suite, joined)
        self.assertTrue(all(line.startswith("test ") for line in lines))

    def test_glob(self):
        self.assertTrue(fs.matches("a/b/c.swift", ["a/**"]))
        self.assertTrue(fs.matches("a/c.md", ["a/**/*.md"]))
        self.assertTrue(fs.matches("a/b/c.md", ["a/**/*.md"]))
        self.assertFalse(fs.matches("a/b/c.swift", ["a/*.swift"]))

    def test_cli_check(self):
        out = subprocess.run([sys.executable, "-I", str(HERE / "select_flows.py"), "--check"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)

    def test_tagged_sim_self_test(self):
        out = subprocess.run(["bash", str(HERE / "tagged-sim.sh"), "self-test"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)


if __name__ == "__main__":
    unittest.main()
