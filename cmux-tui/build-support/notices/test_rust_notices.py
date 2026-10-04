#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fixture tests for rust_notices.py (stdlib unittest; no cargo).

Run: python3 cmux-tui/build-support/notices/test_rust_notices.py
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import rust_notices  # noqa: E402

CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"
GIT = "git+https://github.com/example/gitdep?rev=abc#0123456789abcdef0123456789abcdef01234567"


def sha(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


# name, version, license, extra manifest text, license files, source
REGISTRY = [
    ("lib", "1.0.0", "MIT", "", {"LICENSE-MIT": "MIT text lib\n"}, CRATES_IO),
    ("opt", "1.0.0", "Apache-2.0", "", {"LICENSE": "Apache text opt\n"}, CRATES_IO),
    ("unixonly", "1.0.0", "MIT", "", {"LICENSE": "MIT text unixonly\n"}, CRATES_IO),
    ("winonly", "1.0.0", "MIT", "", {"LICENSE": "MIT text winonly\n"}, CRATES_IO),
    ("devonly", "1.0.0", "MIT", "", {"LICENSE": "MIT text devonly\n"}, CRATES_IO),
    ("buildonly", "1.0.0", "MIT", "", {"LICENSE": "MIT text buildonly\n"}, CRATES_IO),
    ("macro", "1.0.0", "MIT", "[lib]\nproc-macro = true\n[dependencies]\nmacrodep = \"1\"\n", {"LICENSE": "MIT text macro\n"}, CRATES_IO),
    ("macrodep", "1.0.0", "MIT", "", {"LICENSE": "MIT text macrodep\n"}, CRATES_IO),
    ("triple", "2.0.0", "MIT/Apache-2.0", "", {"COPYRIGHT": "triple copyright\n", "LICENSE-MIT": "MIT text lib\n"}, CRATES_IO),
    ("nolicense", "0.1.0", None, "", {"COPYING": "custom terms nolicense\n"}, CRATES_IO),
    ("gitdep", "0.3.0", "MIT", "", {"LICENSE": "MIT text gitdep\n"}, GIT),
]

APP_MANIFEST = """\
[package]
name = "app"
version.workspace = true
license.workspace = true

[dependencies]
lib = "1"
opt = { version = "1", optional = true }
macro = "1"
triple = "2"
nolicense = "0.1"
gitdep = { git = "https://github.com/example/gitdep", rev = "abc" }

[dev-dependencies]
devonly = "1"

[build-dependencies]
buildonly = "1"

[target.'cfg(windows)'.dependencies]
winonly = "1"

[target.'cfg(all(unix, not(target_os = "linux")))'.dependencies]
unixonly = "1"
"""

LOCK_EDGES = {
    "app": ["lib", "opt", "macro", "triple", "nolicense", "gitdep", "devonly", "buildonly", "winonly", "unixonly"],
    "macro": ["macrodep"],
}

FIRST_PARTY_LICENSE = "Copyright Manaflow\n\nGPL text\n"


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        self.ws = root / "ws"
        self.vendor = root / "vendor"
        self.cargo_home = root / "cargo-home"
        self.cargo_home.mkdir()
        (self.ws / "crates/app").mkdir(parents=True)
        (self.ws / "Cargo.toml").write_text(
            '[workspace]\nmembers = ["crates/*"]\n[workspace.package]\nversion = "0.1.0"\nlicense = "GPL-3.0-or-later"\n'
        )
        (self.ws / "crates/app/Cargo.toml").write_text(APP_MANIFEST)
        self.license = root / "FIRST_PARTY_LICENSE"
        self.license.write_text(FIRST_PARTY_LICENSE)
        lock = ["version = 4", ""]
        lock += ["[[package]]", 'name = "app"', 'version = "0.1.0"', "dependencies = ["]
        lock += [f' "{d}",' for d in LOCK_EDGES["app"]] + ["]", ""]
        for name, version, license, extra, files, source in REGISTRY:
            crate = self.vendor / f"{name}-{version}"
            crate.mkdir(parents=True)
            manifest = f'[package]\nname = "{name}"\nversion = "{version}"\n'
            if license:
                manifest += f'license = "{license}"\n'
            (crate / "Cargo.toml").write_text(manifest + extra)
            for file_name, text in files.items():
                (crate / file_name).write_text(text)
            lock += ["[[package]]", f'name = "{name}"', f'version = "{version}"', f'source = "{source}"']
            if source == CRATES_IO:
                lock.append(f'checksum = "{sha(name + version)}"')
            if name in LOCK_EDGES:
                lock += ["dependencies = ["] + [f' "{d}",' for d in LOCK_EDGES[name]] + ["]"]
            lock.append("")
        self.lock = root / "Cargo.lock"
        self.lock.write_text("\n".join(lock))
        self.reviewed_data = {
            "elections": {"triple": {"declared": "MIT OR Apache-2.0", "concluded": "MIT", "reason": "fixture"}}
        }

    def write_reviewed(self) -> Path:
        path = self.root / "reviewed.json"
        path.write_text(json.dumps(self.reviewed_data))
        return path

    def args(self, *extra: str, fmt: str = "spdx-json", targets: tuple[str, ...] = ("aarch64-apple-darwin",)) -> list[str]:
        return [
            "--lock", str(self.lock),
            "--root", "app",
            *[arg for t in targets for arg in ("--target", t)],
            "--sources", str(self.vendor),
            "--workspace", str(self.ws),
            "--first-party", "crates/*",
            "--first-party-license", str(self.license),
            "--source-tag", "cmux-tui-src-b8feb806d6e",
            "--reviewed", str(self.write_reviewed()),
            "--spdx-prefix", "cmux-tui-rust-",
            "--format", fmt,
            *extra,
        ]


def run(argv: list[str]) -> tuple[int, str]:
    err = io.StringIO()
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
        code = rust_notices.main(argv)
    return code, err.getvalue()


def tree(root: Path) -> dict[str, bytes]:
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}


class RustNoticesTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.fx = Fixture(self.tmp)
        self._env = os.environ.get("CARGO_HOME")
        os.environ["CARGO_HOME"] = str(self.fx.cargo_home)

    def tearDown(self) -> None:
        if self._env is None:
            os.environ.pop("CARGO_HOME", None)
        else:
            os.environ["CARGO_HOME"] = self._env
        self._tmp.cleanup()

    def generate(self, name: str, *extra: str, fmt: str = "spdx-json", targets: tuple[str, ...] = ("aarch64-apple-darwin",)) -> tuple[int, str, Path, Path]:
        out = self.tmp / name / "out"
        files = self.tmp / name / "files"
        code, err = run(self.fx.args("--out", str(out), "--files-out", str(files), *extra, fmt=fmt, targets=targets))
        return code, err, out, files

    def spdx(self, name: str = "spdx") -> dict:
        code, err, out, _ = self.generate(name)
        self.assertEqual(code, 0, err)
        return json.loads(out.read_text())

    # Closure ------------------------------------------------------------------

    def test_closure_keeps_normal_optional_and_true_cfg_only(self) -> None:
        names = sorted(p["name"] for p in self.spdx()["packages"])
        self.assertEqual(
            names,
            sorted("cmux-tui-rust-" + n for n in ["app", "gitdep", "lib", "nolicense", "opt", "triple", "unixonly"]),
        )

    def test_linux_target_drops_the_not_linux_cfg(self) -> None:
        code, err, out, _ = self.generate("linux", targets=("x86_64-unknown-linux-gnu",))
        self.assertEqual(code, 0, err)
        names = {p["name"] for p in json.loads(out.read_text())["packages"]}
        self.assertNotIn("cmux-tui-rust-unixonly", names)

    def test_several_targets_give_the_union(self) -> None:
        code, err, out, _ = self.generate("union", targets=("x86_64-unknown-linux-gnu", "x86_64-pc-windows-msvc", "x86_64-apple-darwin"))
        self.assertEqual(code, 0, err)
        names = {p["name"] for p in json.loads(out.read_text())["packages"]}
        self.assertTrue({"cmux-tui-rust-unixonly", "cmux-tui-rust-winonly"} <= names, names)

    def test_cargo_tree_narrows_and_must_be_a_subset(self) -> None:
        exact = self.tmp / "tree.txt"
        exact.write_text("app v0.1.0 (/x)\nlib v1.0.0\ntriple v2.0.0\nnolicense v0.1.0\ngitdep v0.3.0 (https://x)\nmacro v1.0.0 (proc-macro)\n")
        code, err, out, _ = self.generate("tree", "--cargo-tree", str(exact))
        self.assertEqual(code, 0, err)
        names = sorted(p["name"].removeprefix("cmux-tui-rust-") for p in json.loads(out.read_text())["packages"])
        self.assertEqual(names, ["app", "gitdep", "lib", "nolicense", "triple"])
        exact.write_text("app v0.1.0\ndevonly v1.0.0\n")
        code, err, _, _ = self.generate("tree-bad", "--cargo-tree", str(exact))
        self.assertEqual(code, 1)
        self.assertIn("devonly 1.0.0", err)

    # Determinism ----------------------------------------------------------------

    def test_two_runs_are_byte_equal(self) -> None:
        for fmt in ("spdx-json", "markdown"):
            code_a, err_a, out_a, files_a = self.generate(f"a-{fmt}", fmt=fmt)
            code_b, err_b, out_b, files_b = self.generate(f"b-{fmt}", fmt=fmt)
            self.assertEqual((code_a, code_b), (0, 0), err_a + err_b)
            self.assertEqual(out_a.read_bytes(), out_b.read_bytes())
            self.assertEqual(tree(files_a), tree(files_b))

    def test_rerun_into_an_old_files_out_equals_a_fresh_run(self) -> None:
        _, _, _, fresh = self.generate("fresh")
        stale = self.tmp / "rerun" / "files"
        (stale / "lib-0.9.0").mkdir(parents=True)
        (stale / "lib-0.9.0" / "LICENSE").write_text("old crate version\n")
        code, err, _, files = self.generate("rerun")
        self.assertEqual(code, 0, err)
        self.assertEqual(tree(files), tree(fresh))

    def test_files_out_with_foreign_entries_is_not_cleaned(self) -> None:
        files = self.tmp / "foreign" / "files"
        files.mkdir(parents=True)
        (files / "Info.plist").write_text("not ours\n")
        code, err, _, _ = self.generate("foreign")
        self.assertEqual(code, 1)
        self.assertIn("refusing to clean", err)
        self.assertEqual((files / "Info.plist").read_text(), "not ours\n")

    def test_check_passes_when_fresh_and_fails_when_stale(self) -> None:
        code, err, out, files = self.generate("check")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.generate("check", "--check")[0], 0)
        (files / "lib-1.0.0" / "LICENSE-MIT").write_text("edited\n")
        code, err, _, _ = self.generate("check", "--check")
        self.assertEqual(code, 1)
        self.assertIn("stale", err)

    # Elections ------------------------------------------------------------------

    def test_election_sets_concluded_and_keeps_declared(self) -> None:
        triple = next(p for p in self.spdx()["packages"] if p["name"] == "cmux-tui-rust-triple")
        self.assertEqual(triple["licenseConcluded"], "MIT")
        self.assertEqual(triple["licenseDeclared"], "MIT OR Apache-2.0")

    def test_election_fails_when_the_declared_expression_changes(self) -> None:
        self.fx.reviewed_data["elections"]["triple"]["declared"] = "MIT OR Apache-2.0 OR Zlib"
        code, err, _, _ = self.generate("changed")
        self.assertEqual(code, 1)
        self.assertIn("triple 2.0.0", err)

    def test_election_must_pick_one_declared_alternative(self) -> None:
        self.fx.reviewed_data["elections"]["triple"]["concluded"] = "BSD-3-Clause"
        code, err, _, _ = self.generate("not-an-option")
        self.assertEqual(code, 1)
        self.assertIn("BSD-3-Clause", err)

    def test_or_alternatives(self) -> None:
        cases = {
            "MIT OR Apache-2.0 OR LGPL-2.1-or-later": ["MIT", "Apache-2.0", "LGPL-2.1-or-later"],
            "(MIT OR Apache-2.0) AND Unicode-3.0": ["(MIT OR Apache-2.0) AND Unicode-3.0"],
            "(MIT OR Apache-2.0) AND (Zlib OR ISC)": ["(MIT OR Apache-2.0) AND (Zlib OR ISC)"],
            "(MIT OR Apache-2.0) OR Zlib": ["MIT OR Apache-2.0", "Zlib"],
            "Apache-2.0 WITH LLVM-exception OR MIT": ["Apache-2.0 WITH LLVM-exception", "MIT"],
        }
        for expression, terms in cases.items():
            self.assertEqual(rust_notices.or_alternatives(expression), terms, expression)

    def test_shipped_reviewed_json_is_consistent(self) -> None:
        reviewed = rust_notices.Reviewed.load(Path(__file__).resolve().parent / "reviewed.json")
        for key, election in reviewed.elections.items():
            self.assertTrue(election.get("reason"), key)
            self.assertIn(election["concluded"], rust_notices.or_alternatives(election["declared"]), key)
        for key, text in reviewed.texts.items():
            self.assertTrue(text.get("reason"), key)
            self.assertTrue(text["files"], key)
            for entry in text["files"]:
                data = (reviewed.base / entry["file"]).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), entry["sha256"], key)
                self.assertRegex(entry["source"], r"^https://raw\.githubusercontent\.com/[^/]+/[^/]+/[0-9a-f]{40}/", key)

    def test_reviewed_rejects_unknown_keys(self) -> None:
        self.fx.reviewed_data["overrides"] = {}
        self.assertEqual(self.generate("unknown")[0], 1)

    def test_git_crate_in_a_workspace_uses_the_checkout_license_and_workspace_fields(self) -> None:
        import shutil

        shutil.rmtree(self.fx.vendor / "gitdep-0.3.0")
        checkout = self.fx.cargo_home / "git" / "checkouts" / "gitdep-1a2b3c" / "0123456"
        (checkout / "crates" / "gitdep").mkdir(parents=True)
        (checkout / "Cargo.toml").write_text('[workspace]\nmembers = ["crates/*"]\n[workspace.package]\nversion = "0.3.0"\nlicense = "MIT"\n')
        (checkout / "crates" / "gitdep" / "Cargo.toml").write_text('[package]\nname = "gitdep"\nversion.workspace = true\nlicense.workspace = true\n')
        (checkout / "LICENSE-MIT").write_text("MIT text gitdep repository\n")
        code, err, out, files = self.generate("git")
        self.assertEqual(code, 0, err)
        gitdep = next(p for p in json.loads(out.read_text())["packages"] if p["name"] == "cmux-tui-rust-gitdep")
        self.assertEqual(gitdep["licenseDeclared"], "MIT")
        self.assertEqual(tree(files)["gitdep-0.3.0/repository-LICENSE-MIT"], b"MIT text gitdep repository\n")

    # Texts ----------------------------------------------------------------------

    def test_missing_license_text_fails(self) -> None:
        (self.fx.vendor / "lib-1.0.0" / "LICENSE-MIT").unlink()
        code, err, _, _ = self.generate("missing")
        self.assertEqual(code, 1)
        self.assertIn("lib 1.0.0", err)

    def test_files_are_verbatim_and_spdx_points_at_them(self) -> None:
        code, err, out, files = self.generate("files")
        self.assertEqual(code, 0, err)
        doc = json.loads(out.read_text())
        written = tree(files)
        self.assertEqual(written["triple-2.0.0/COPYRIGHT"], b"triple copyright\n")
        self.assertEqual(written["app-0.1.0/LICENSE"], FIRST_PARTY_LICENSE.encode())
        self.assertEqual(sorted(f["fileName"] for f in doc["files"]), sorted(written))
        for entry in doc["files"]:
            self.assertEqual(entry["licenseConcluded"], "NOASSERTION")
            self.assertEqual(entry["checksums"], [{"algorithm": "SHA256", "checksumValue": hashlib.sha256(written[entry["fileName"]]).hexdigest()}])

    def test_reviewed_extra_files_and_texts(self) -> None:
        (self.fx.vendor / "lib-1.0.0" / "AUTHORS").write_text("lib authors\n")
        (self.fx.root / "texts").mkdir()
        (self.fx.root / "texts" / "opt-NOTICE.txt").write_text("reviewed opt text\n")
        self.fx.reviewed_data["extra_license_files"] = {"lib": ["AUTHORS"]}
        entry = {"file": "texts/opt-NOTICE.txt", "source": "https://example.invalid/opt@abc/NOTICE", "sha256": sha("reviewed opt text\n")}
        self.fx.reviewed_data["license_texts"] = {"opt 1.0.0": {"reason": "fixture", "files": [entry]}}
        code, err, _, files = self.generate("reviewed")
        self.assertEqual(code, 0, err)
        written = tree(files)
        self.assertEqual(written["lib-1.0.0/AUTHORS"], b"lib authors\n")
        self.assertEqual(written["opt-1.0.0/reviewed-opt-NOTICE.txt"], b"reviewed opt text\n")
        entry["sha256"] = "0" * 64
        code, err, _, _ = self.generate("reviewed-bad-sum")
        self.assertEqual(code, 1)
        self.assertIn("does not match its sha256", err)

    def test_non_utf8_text_fails_instead_of_being_rewritten(self) -> None:
        (self.fx.vendor / "lib-1.0.0" / "LICENSE-MIT").write_bytes(b"caf\xe9\n")
        code, err, _, _ = self.generate("latin1", fmt="markdown")
        self.assertEqual(code, 1)
        self.assertIn("UTF-8", err)

    def test_vendor_checksum_must_match_the_lock(self) -> None:
        (self.fx.vendor / "lib-1.0.0" / ".cargo-checksum.json").write_text(json.dumps({"files": {}, "package": sha("lib1.0.0")}))
        self.assertEqual(self.generate("ok-sum")[0], 0)
        (self.fx.vendor / "lib-1.0.0" / ".cargo-checksum.json").write_text(json.dumps({"files": {}, "package": "0" * 64}))
        code, err, _, _ = self.generate("bad-sum")
        self.assertEqual(code, 1)
        self.assertIn("checksum", err)

    # SPDX shape -------------------------------------------------------------------

    def test_spdx_package_fields(self) -> None:
        doc = self.spdx()
        by_name = {p["name"]: p for p in doc["packages"]}
        app = by_name["cmux-tui-rust-app"]
        self.assertEqual(app["versionInfo"], "0.1.0")
        self.assertEqual(app["licenseDeclared"], "GPL-3.0-or-later")
        self.assertEqual(app["downloadLocation"], "https://github.com/manaflow-ai/cmux/tree/cmux-tui-src-b8feb806d6e/cmux-tui/crates/app")
        lib = by_name["cmux-tui-rust-lib"]
        self.assertEqual(lib["downloadLocation"], "https://crates.io/api/v1/crates/lib/1.0.0/download")
        self.assertEqual(lib["checksums"], [{"algorithm": "SHA256", "checksumValue": sha("lib1.0.0")}])
        gitdep = by_name["cmux-tui-rust-gitdep"]
        self.assertEqual(gitdep["downloadLocation"], "git+https://github.com/example/gitdep@0123456789abcdef0123456789abcdef01234567")
        for package in doc["packages"]:
            self.assertNotIn(package["versionInfo"], package["name"])
        ids = [p["SPDXID"] for p in doc["packages"]] + [f["SPDXID"] for f in doc["files"]]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(doc["creationInfo"]["created"], "1970-01-01T00:00:00Z")

    def test_repo_root_sets_first_party_paths(self) -> None:
        argv = self.fx.args("--out", str(self.tmp / "rr.json"))
        index = argv.index("--first-party")
        argv[index + 1] = "ws/crates/*"
        code, err = run([*argv, "--repo-root", str(self.fx.root)])
        self.assertEqual(code, 0, err)
        app = next(p for p in json.loads((self.tmp / "rr.json").read_text())["packages"] if p["name"] == "cmux-tui-rust-app")
        self.assertEqual(app["downloadLocation"], "https://github.com/manaflow-ai/cmux/tree/cmux-tui-src-b8feb806d6e/ws/crates/app")

    def test_path_download_names_third_party_path_packages(self) -> None:
        (self.fx.ws / "crates/app/LICENSE").write_text("third-party app license\n")
        argv = self.fx.args("--out", str(self.tmp / "pd.json"), "--path-download", "git+https://example.invalid/ws@abc")
        argv[argv.index("--first-party") + 1] = "nothing/*"
        code, err = run(argv)
        self.assertEqual(code, 0, err)
        app = next(p for p in json.loads((self.tmp / "pd.json").read_text())["packages"] if p["name"] == "cmux-tui-rust-app")
        self.assertEqual(app["downloadLocation"], "git+https://example.invalid/ws@abc")

    def test_extracted_texts_only_for_licenseref(self) -> None:
        doc = self.spdx()
        nolicense = next(p for p in doc["packages"] if p["name"] == "cmux-tui-rust-nolicense")
        self.assertEqual(nolicense["licenseDeclared"], "LicenseRef-nolicense-0.1.0")
        self.assertEqual(
            doc["hasExtractedLicensingInfos"],
            [{"licenseId": "LicenseRef-nolicense-0.1.0", "extractedText": "custom terms nolicense\n"}],
        )


if __name__ == "__main__":
    unittest.main()
