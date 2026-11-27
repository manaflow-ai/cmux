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
        for n in list(range(1, 13)) + [21]:
            self.assertIn(f"regression:{n}", rows)

    def test_composer_layout_change_runs_its_tests(self):
        r = fs.select(MANIFEST, ["cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTerminal/Composer/TerminalComposer.swift"])
        self.assertIn("composer-grow-and-controls", [f["id"] if isinstance(f, dict) else f for f in r["flows"]])


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

    def test_every_crate_the_ffi_compiles_is_ios_affecting(self):
        # The crates come from the FFI's Cargo graph (scripts/ci/ios_link_ffi_key.py), not a list: cmux-wg and
        # cmux-felt were outside the old path walk (the 2026-11 audit: 254 shared-Rust PRs never built for iOS).
        sys.path.insert(0, str(fs.REPO / "scripts/ci"))
        import ios_link_ffi_key as key
        sys.path.pop(0)
        crates, roots = fs.ffi_closure(fs.REPO)
        self.assertIn("cmux-tui/crates/cmux-wg", crates)
        self.assertEqual(crates, key.closure("HEAD")[0])
        for d in crates + [f"{r}/Cargo.lock" for r in roots]:
            r = self.sel(d if d.endswith(".lock") else f"{d}/src/lib.rs")
            self.assertTrue(r["compile"], d)
            self.assertIn("compile-app-and-tests", r["flows"], d)

    def test_redial_change_runs_the_reconnect_flow_on_a_paired_mac(self):
        for path in ("cmux-tui/crates/cmux-remote/src/connection.rs", "cmux-tui/crates/cmux-tui/src/remote_runtime.rs"):
            r = self.sel(path)
            self.assertIn("reconnect-after-drop", r["flows"], path)
            self.assertEqual(r["pair_e2e"], ["reconnect-drops=10,60"])
            self.assertEqual(fs.sim_args(r, 1)[-1], "pair-e2e reconnect-drops=10,60")
        self.assertNotIn("reconnect-after-drop", self.sel("cmux-tui/crates/cmux-tui/src/main.rs")["flows"])

    def test_pair_e2e_true_runs_the_paired_mac_with_no_words(self):
        # flows.json writes "pair_e2e": true for a flow that needs the paired run with its defaults;
        # select() iterated it as a list and crashed `cmux ios verify` on every PR that selected it.
        r = self.sel("Packages/macOS/CmuxNext/Sources/CmuxNextMobileHost/Host.swift")
        self.assertIn("pairing-mac-identity", r["flows"])
        self.assertTrue(r["pair"])
        self.assertEqual(fs.sim_args(r, 1)[-1].split()[0], "pair-e2e")

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
