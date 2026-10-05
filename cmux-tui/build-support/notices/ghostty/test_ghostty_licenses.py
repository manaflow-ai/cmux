#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for collect-ghostty-licenses.py and verify-ghostty-license-bundle.py.

Moved from manaflow-ai/cmux-browser scripts/test-ghostty-license-path-budget.py
(cc93624d); the tools now live here and cmux-browser vendors them.

The collected Ghostty license tree must stay extraction-path bounded.

Production run 33259127761 failed Windows installation with
ERROR_FILENAME_EXCED_RANGE because the dependency-licenses tree mirrored
zig-pkg source paths verbatim. The collector now emits
`<label>/<hash12>-<basename>` destinations and the verifier rejects any
destination over its budget; this test pins both behaviors.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import shutil
import socket
from pathlib import Path
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
COLLECTOR = HERE / "collect-ghostty-licenses.py"
VERIFIER = HERE / "verify-ghostty-license-bundle.py"
REVISION = "a" * 40
# The cmux Browser release text, as cmux-browser passes it.
RELEASE_OFFER = (
    "the cmux Browser release source archive "
    "cmux-browser-source-<version>.tar.zst and its "
    "corresponding-source.json, published with this release at "
    "https://github.com/manaflow-ai/cmux-v2/releases/download/<tag>/ "
    "(tag nightly-<version> for a nightly build, "
    "v<version> for a stable or release-candidate build). The archive "
    "embeds every Ghostty Zig package archive, including this one."
)
MAX_DESTINATION_CHARS = 80


def run(script: Path, *args: object) -> subprocess.CompletedProcess[str]:
    if script == COLLECTOR:
        args = (*args, "--release-source-offer", RELEASE_OFFER)
    return subprocess.run(
        [sys.executable, str(script), *(str(argument) for argument in args)],
        check=False,
        capture_output=True,
        text=True,
    )


def build_fixture(work: Path) -> tuple[Path, Path]:
    source = work / "ghostty-src"
    deep = (
        source
        / "zig-pkg/N-V-__8AADcZkgn4cMhTUpIz6mShCKyqqB-NBtf_S2bHaTC-"
        / "gettext-tools/tree-sitter-0.23.2/lib/src/unicode"
    )
    deep.mkdir(parents=True)
    (source / "LICENSE").write_text("ghostty MIT\n")
    (deep / "LICENSE").write_text("tree-sitter unicode terms\n")
    cache = work / "zig-cache"
    package = cache / "p/N-V-__8AAG02ugUcWec-Ndp-i7JTsJ0dgF8nnJRUInkGLG7G"
    nested = package / "vendor/some/deeply/nested/directory/tree"
    nested.mkdir(parents=True)
    (package / "LICENSE.markdown-with-a-very-long-license-basename.txt").write_text(
        "package license\n"
    )
    (nested / "COPYING").write_text("nested copying\n")
    other = cache / "p/AAAA-short-package"
    other.mkdir(parents=True)
    (other / "NOTICE").write_text("short package notice\n")
    return source, cache


def test_bounded_round_trip() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-ghostty-path-budget-") as raw:
        work = Path(raw)
        source, cache = build_fixture(work)
        output = work / "collected"
        result = run(
            COLLECTOR,
            "--ghostty-source",
            source,
            "--zig-cache",
            cache,
            "--output",
            output,
            "--revision",
            REVISION,
        )
        assert result.returncode == 0, result.stderr
        manifest = json.loads((output / "SOURCE-MANIFEST.json").read_text())
        entries = manifest["license_files"]
        assert len(entries) == 5, [entry["destination"] for entry in entries]
        sources = {entry["source"] for entry in entries}
        assert (
            "zig-pkg/N-V-__8AADcZkgn4cMhTUpIz6mShCKyqqB-NBtf_S2bHaTC-/"
            "gettext-tools/tree-sitter-0.23.2/lib/src/unicode/LICENSE" in sources
        ), "original deep source path must survive in the manifest index"
        for entry in entries:
            destination = entry["destination"]
            assert len(destination) <= MAX_DESTINATION_CHARS, destination
            assert len(Path(destination).parts) == 2, destination
            content = (output / destination).read_bytes()
            assert hashlib.sha256(content).hexdigest() == entry["sha256"]
        verified = run(VERIFIER, "--root", output, "--revision", REVISION)
        assert verified.returncode == 0, verified.stderr


def test_zig_package_index() -> None:
    """The manifest names each Zig package by its build.zig.zon dependency.

    Ghostty's own manifest wins over one inside a fetched package, a `//`
    inside a URL is not a comment, and a package without license files or
    without a declaration is not indexed.
    """
    with tempfile.TemporaryDirectory(prefix="cmux-ghostty-path-budget-") as raw:
        work = Path(raw)
        source, cache = build_fixture(work)
        gettext = "N-V-__8AADcZkgn4cMhTUpIz6mShCKyqqB-NBtf_S2bHaTC-"
        (source / "pkg/libintl").mkdir(parents=True)
        (source / "pkg/libintl/build.zig.zon").write_text(
            ".{\n"
            "    .name = .libintl,\n"
            "    .dependencies = .{\n"
            f"        // .a_gettext = .{{ .url = \"https://x/old.tar.gz\", .hash = \"{gettext}\" }},\n"
            "        .gettext = .{\n"
            "            .url = \"https://deps.files.ghostty.org/gettext-0.24.tar.gz\", // pinned\n"
            f"            .hash = \"{gettext}\",\n"
            "            .lazy = true,\n"
            "        },\n"
            "        .apple_sdk = .{ .path = \"../apple-sdk\" },\n"
            "    },\n"
            "}\n"
        )
        # A fetched package declares the same archive under another name.
        nested = source / "zig-pkg/vaxis-0.6.0-BWNV_CrbCQCscGpzsAlR402rYQ_tV3aAl081c2iRRkka"
        nested.mkdir(parents=True)
        (nested / "LICENSE").write_text("vaxis MIT\n")
        (nested / "build.zig.zon").write_text(
            ".{ .name = .vaxis, .dependencies = .{\n"
            f"    .aaa_gettext = .{{ .url = \"git+https://example.com/g#1\", .hash = \"{gettext}\" }},\n"
            "} }\n"
        )
        (source / "build.zig.zon").write_text(
            ".{ .name = .ghostty, .dependencies = .{\n"
            "    .vaxis = .{\n"
            "        .url = \"https://deps.files.ghostty.org/vaxis-1dbbe57.tar.gz\",\n"
            "        .hash = \"vaxis-0.6.0-BWNV_CrbCQCscGpzsAlR402rYQ_tV3aAl081c2iRRkka\",\n"
            "    },\n"
            "    .unfetched = .{ .url = \"https://x/u.tar.gz\", .hash = \"N-V-unfetched\" },\n"
            "} }\n"
        )
        output = work / "collected"
        result = run(
            COLLECTOR, "--ghostty-source", source, "--zig-cache", cache,
            "--output", output, "--revision", REVISION,
        )
        assert result.returncode == 0, result.stderr
        manifest = json.loads((output / "SOURCE-MANIFEST.json").read_text())
        assert manifest["zig_packages"] == {
            gettext: {
                "dependency": "gettext",
                "url": "https://deps.files.ghostty.org/gettext-0.24.tar.gz",
            },
            "vaxis-0.6.0-BWNV_CrbCQCscGpzsAlR402rYQ_tV3aAl081c2iRRkka": {
                "dependency": "vaxis",
                "url": "https://deps.files.ghostty.org/vaxis-1dbbe57.tar.gz",
            },
        }, manifest["zig_packages"]
        verified = run(VERIFIER, "--root", output, "--revision", REVISION)
        assert verified.returncode == 0, verified.stderr

        # An index entry must belong to a package with license files.
        manifest["zig_packages"]["N-V-unfetched"] = {
            "dependency": "unfetched",
            "url": "https://x/u.tar.gz",
        }
        (output / "SOURCE-MANIFEST.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        )
        rejected = run(VERIFIER, "--root", output, "--revision", REVISION)
        assert rejected.returncode != 0
        assert "has no license files" in rejected.stderr, rejected.stderr


def test_zig_pkg_package_without_license_is_unresolved() -> None:
    """A zig-pkg package with no license file fails the collection.

    Zig 0.16 fetches every package into the Ghostty source's zig-pkg/, and
    a package's build.zig.zon `.paths` can drop its LICENSE (z2d) or the
    archive can have none (Dear Bindings). Run 37197552019 shipped both
    without a notice because only package-cache roots were checked.
    """
    with tempfile.TemporaryDirectory(prefix="cmux-ghostty-path-budget-") as raw:
        work = Path(raw)
        source, cache = build_fixture(work)
        silent = source / "zig-pkg/N-V-__8AAUnlicensedPackageWithoutAnyNoticeX"
        (silent / "src").mkdir(parents=True)
        (silent / "src/lib.c").write_text("int f(void) { return 0; }\n")
        result = run(
            COLLECTOR, "--ghostty-source", source, "--zig-cache", cache,
            "--output", work / "collected", "--revision", REVISION,
        )
        assert result.returncode != 0, result.stdout
        assert "without discoverable license files" in result.stderr, result.stderr
        assert silent.name in result.stderr, result.stderr
        # The failure says how to fix it: pin a reviewed text.
        assert "pinned-licenses/MANIFEST.json" in result.stderr, result.stderr
        manifest = json.loads((work / "collected/SOURCE-MANIFEST.json").read_text())
        assert manifest["unresolved_packages"] == [silent.name]


Z2D = "z2d-0.11.0-j5P_HtLzDwBGyQt49DrT0v4BuVqI_SRs6CXsuj7eBVhR"
BINDINGS = "N-V-__8AANT61wB--nJ95Gj_ctmzAtcjloZ__hRqNw5lC1Kr"


PINNED = HERE / "pinned-licenses"


def collect_in_process(
    source: Path, cache: Path, output: Path, z2d: str = Z2D, pinned: Path = PINNED,
    bindings_package: str = BINDINGS, accept_manifest: bool = False,
) -> int:
    """Run the collector with network access disabled. accept_manifest: a
    test edited the pinned manifest on purpose, so accept its digest."""
    spec = importlib.util.spec_from_file_location("ghostty_collector", COLLECTOR)
    assert spec is not None and spec.loader is not None
    collector = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(collector)
    collector.PINNED_LICENSES = pinned
    if accept_manifest:
        collector.PINNED_MANIFEST_SHA256 = hashlib.sha256(
            (pinned / "MANIFEST.json").read_bytes()
        ).hexdigest()
    package = source / "zig-pkg" / z2d
    (package / "src").mkdir(parents=True)
    (package / "src/z2d.zig").write_text("// SPDX-License-Identifier: MPL-2.0\n")
    (package / "build.zig.zon").write_text(
        "// SPDX-License-Identifier: MPL-2.0\n.{ .name = .z2d, .version = \"0.11.0\" }\n"
    )
    bindings = source / "zig-pkg" / bindings_package
    bindings.mkdir(parents=True)
    (bindings / "dcimgui.cpp").write_text("// generated\n")
    (bindings / "dcimgui.h").write_text("// generated\n")
    (source / "build.zig.zon").write_text(
        ".{ .name = .ghostty, .dependencies = .{\n"
        f"    .z2d = .{{ .url = \"https://deps.files.ghostty.org/{z2d}.tar.gz\", .hash = \"{z2d}\" }},\n"
        f"    .bindings = .{{ .url = \"https://deps.files.ghostty.org/db.tar.gz\", .hash = \"{bindings_package}\" }},\n"
        "} }\n"
    )

    def no_network(*_args, **_kwargs):
        raise AssertionError("the collector must not open a network connection")

    arguments, connect = sys.argv, socket.socket.connect
    sys.argv = [
        str(COLLECTOR), "--ghostty-source", str(source), "--zig-cache", str(cache),
        "--output", str(output), "--revision", REVISION,
        "--release-source-offer", RELEASE_OFFER,
    ]
    socket.socket.connect = no_network
    try:
        return collector.main()
    except SystemExit as error:
        return int(error.code or 0)
    finally:
        sys.argv, socket.socket.connect = arguments, connect


def test_known_zig_pkg_licenses() -> None:
    """z2d and Dear Bindings ship the texts pinned in the repository, and z2d
    its MPL-2.0 source offer, offline; another z2d version, a changed text,
    or a changed manifest fails collection."""
    manifest = json.loads((PINNED / "MANIFEST.json").read_text())
    for known in manifest["packages"].values():
        for item in known["files"]:
            content = (PINNED / item["path"]).read_bytes()
            assert hashlib.sha256(content).hexdigest() == item["sha256"], item["path"]
    with tempfile.TemporaryDirectory(prefix="cmux-ghostty-path-budget-") as raw:
        work = Path(raw)
        source, cache = build_fixture(work)
        output = work / "collected"
        assert collect_in_process(source, cache, output) == 0
        collected = json.loads((output / "SOURCE-MANIFEST.json").read_text())
        assert collected["unresolved_packages"] == []
        by_package: dict[str, dict[str, dict]] = {}
        for entry in collected["license_files"]:
            by_package.setdefault(entry["package"], {})[entry["source"]] = entry
        z2d = by_package[Z2D]
        for item in manifest["packages"]["z2d"]["files"]:
            entry = z2d[item["upstream"]]
            assert entry["source_kind"] == "verified-upstream-license"
            assert (output / entry["destination"]).read_bytes() == (PINNED / item["path"]).read_bytes()
        assert "Mozilla Public License Version 2.0" in (PINNED / "z2d-0.11.0/COPYING").read_text()
        offer = z2d[f"source-offer:{Z2D}"]
        assert offer["source_kind"] == "generated-source-offer"
        text = (output / offer["destination"]).read_text()
        assert "z2d 0.11.0 is licensed under the Mozilla Public License 2.0" in text
        assert f"https://deps.files.ghostty.org/{Z2D}.tar.gz" in text
        assert f"Zig package {Z2D}" in text
        assert "https://github.com/vancluever/z2d/tree/5184a79622dce6b885c45ef6666f8c92385bed10" in text
        assert "corresponding-source.json, published with this release" in text
        assert "beside this binary" not in text
        assert "cmux-browser-source-<version>.tar.zst" in text
        assert "https://github.com/manaflow-ai/cmux-v2/releases/download/<tag>/" in text
        zon = next(
            entry for entry in collected["license_files"]
            if entry["source"] == f"zig-pkg/{Z2D}/build.zig.zon"
        )
        assert zon["source_kind"] == "ghostty"
        [bindings] = by_package[BINDINGS].values()
        assert (output / bindings["destination"]).read_bytes() == (
            PINNED / "dear-bindings-0.17/LICENSE.txt"
        ).read_bytes()
        assert collected["zig_packages"][Z2D]["dependency"] == "z2d"
        assert collected["zig_packages"][BINDINGS]["dependency"] == "bindings"
        verified = run(VERIFIER, "--root", output, "--revision", REVISION)
        assert verified.returncode == 0, verified.stderr

    def fails(label: str, mutate, z2d: str = Z2D, bindings: str = BINDINGS) -> None:
        with tempfile.TemporaryDirectory(prefix="cmux-ghostty-path-budget-") as raw:
            work = Path(raw)
            pinned = work / "pinned"
            shutil.copytree(PINNED, pinned)
            mutate(pinned)
            source, cache = build_fixture(work)
            status = collect_in_process(
                source, cache, work / "collected", z2d, pinned, bindings
            )
            assert status != 0, label

    fails("z2d bump", lambda pinned: None,
          z2d="z2d-0.12.0-AAP_HtLzDwBGyQt49DrT0v4BuVqI_SRs6CXsuj7eBVhR")
    # A Dear Bindings version the texts were not reviewed for stops the
    # build, like a z2d bump.
    fails("dear bindings bump", lambda pinned: None,
          bindings="N-V-__8AAOtherDearBindingsArchiveXXXXXXXXXXXXXXX")
    fails("changed text", lambda pinned: (pinned / "z2d-0.11.0/COPYING").write_text("edited\n"))
    fails("changed manifest", lambda pinned: (pinned / "MANIFEST.json").write_text(
        (pinned / "MANIFEST.json").read_text().replace("tag v0.11.0", "tag v0.11.1")
    ))


THEMES = "N-V-__8AALZGBAAS5NLVH-c8eC-6VtCdcH-9nUvVfUSkWS__"
GOBJECT = "gobject-0.3.1-Skun7E1KnwBGMX5nslHYG1yWHaSevywxQO8oM7tTOgIp"


def add_themes_and_gobject(source: Path, themes: str = THEMES, gobject: str = GOBJECT) -> None:
    """The iterm2_themes and zig-gobject packages as Zig fetches them: no license file."""
    theme_dir = source / "zig-pkg" / themes
    theme_dir.mkdir(parents=True)
    for name in ("Ubuntu", "Ayu", "Dracula"):
        (theme_dir / name).write_text("palette = 0=#2e3436\nbackground = #300a24\n")
    gobject_dir = source / "zig-pkg" / gobject
    (gobject_dir / "src/gobject2").mkdir(parents=True)
    (gobject_dir / "src/gobject2/gobject2.zig").write_text("// generated\n")
    (gobject_dir / "build.zig.zon").write_text('.{ .name = .gobject, .version = "0.3.1" }\n')


def test_themes_and_gobject_get_pinned_texts() -> None:
    """iterm2_themes (iTerm2-Color-Schemes) and zig-gobject ship no license
    file; their pinned MIT texts are collected, and another package directory
    of either stops the collection."""
    manifest = json.loads((PINNED / "MANIFEST.json").read_text())
    assert THEMES in manifest["packages"]["iterm2-themes"]["packages"]
    assert GOBJECT in manifest["packages"]["zig-gobject"]["packages"]
    with tempfile.TemporaryDirectory(prefix="cmux-ghostty-path-budget-") as raw:
        work = Path(raw)
        source, cache = build_fixture(work)
        add_themes_and_gobject(source)
        output = work / "collected"
        assert collect_in_process(source, cache, output) == 0
        collected = json.loads((output / "SOURCE-MANIFEST.json").read_text())
        assert collected["unresolved_packages"] == []
        by_package: dict[str, list[dict]] = {}
        for entry in collected["license_files"]:
            by_package.setdefault(entry["package"], []).append(entry)
        for package, name in ((THEMES, "iterm2-themes"), (GOBJECT, "zig-gobject")):
            [entry] = by_package[package]
            assert entry["source_kind"] == "verified-upstream-license", entry
            item = manifest["packages"][name]["files"][0]
            assert (output / entry["destination"]).read_bytes() == (PINNED / item["path"]).read_bytes()
    for label, themes, gobject in (("themes bump", "N-V-__8AAOtherThemesReleaseXXXXXXXXXXXXXXXXXXXX", GOBJECT),
                                   ("gobject bump", THEMES, "gobject-0.4.0-OtherGobjectReleaseXXXXXXXXXXXXXXXXXXXXXXX")):
        with tempfile.TemporaryDirectory(prefix="cmux-ghostty-path-budget-") as raw:
            work = Path(raw)
            source, cache = build_fixture(work)
            add_themes_and_gobject(source, themes, gobject)
            assert collect_in_process(source, cache, work / "collected") != 0, label


Z2D_NEXT = "z2d-0.12.1-j5P_Hsw8EQAKyZTQICCQnAH2xYkLDW8k9uefbsYdfPZ-"
THEMES_NEXT = "N-V-__8AAM94BAAFk_hn4UW0x_OBD2g0vOwexeAAyWNNo4eB"
GOBJECT_NEXT = "gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3"


def test_ghostty_next_packages_get_pinned_texts() -> None:
    """ghostty-next (the libghostty-vt source of bin/cmux) fetches z2d 0.12.1,
    zig-gobject 0.3.2 and a newer iterm2_themes release, none with a license
    file. z2d 0.12.1 ships its own pinned texts and MPL-2.0 source offer; the
    other two reuse texts that are byte-equal upstream."""
    manifest = json.loads((PINNED / "MANIFEST.json").read_text())
    assert manifest["packages"]["z2d@0.12.1"]["packages"] == [Z2D_NEXT]
    with tempfile.TemporaryDirectory(prefix="cmux-ghostty-next-") as raw:
        work = Path(raw)
        source, cache = build_fixture(work)
        add_themes_and_gobject(source, THEMES_NEXT, GOBJECT_NEXT)
        output = work / "collected"
        assert collect_in_process(source, cache, output, z2d=Z2D_NEXT) == 0
        collected = json.loads((output / "SOURCE-MANIFEST.json").read_text())
        assert collected["unresolved_packages"] == []
        z2d = {e["source"]: e for e in collected["license_files"] if e["package"] == Z2D_NEXT}
        for item in manifest["packages"]["z2d@0.12.1"]["files"]:
            entry = z2d[item["upstream"]]
            assert (output / entry["destination"]).read_bytes() == (PINNED / item["path"]).read_bytes()
        offer = (output / z2d[f"source-offer:{Z2D_NEXT}"]["destination"]).read_text()
        assert "z2d 0.12.1 is licensed under the Mozilla Public License 2.0" in offer
        assert "7dbae85c81784dba9988320bf9543ed9a81350c8" in offer
        assert "upstream tag v0.12.1" in offer
        packages = {e["package"] for e in collected["license_files"]}
        assert THEMES_NEXT in packages and GOBJECT_NEXT in packages


def test_vendored_directory_without_license_is_unresolved() -> None:
    """A pkg/ or vendor/ directory with third-party code and no license file
    fails collection until it is reviewed in pinned-licenses/MANIFEST.json.

    Ghostty vendors the simdutf amalgamation in pkg/simdutf/vendor/ and the
    generated glad loader in vendor/glad/, both without a license file; they
    are linked into libghostty and libghostty-vt, and no notice shipped their
    terms because only Zig packages were checked.
    """
    for directory in ("pkg/newlib", "vendor/newgen"):
        with tempfile.TemporaryDirectory(prefix="cmux-ghostty-vendored-") as raw:
            work = Path(raw)
            source, cache = build_fixture(work)
            vendored = source / directory / "vendor"
            vendored.mkdir(parents=True)
            (vendored / "lib.c").write_text("/* third-party code */\nint f(void) { return 0; }\n")
            (source / directory / "build.zig").write_text("// Ghostty's wrapper\n")
            result = run(
                COLLECTOR, "--ghostty-source", source, "--zig-cache", cache,
                "--output", work / "collected", "--revision", REVISION,
            )
            assert result.returncode != 0, (directory, result.stdout)
            assert directory in result.stderr, result.stderr
            assert "pinned-licenses/MANIFEST.json" in result.stderr, result.stderr
            manifest = json.loads((work / "collected/SOURCE-MANIFEST.json").read_text())
            assert any(item.startswith(directory) for item in manifest["unresolved_packages"]), manifest


def test_vendored_directory_with_a_license_file_is_covered() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-ghostty-vendored-") as raw:
        work = Path(raw)
        source, cache = build_fixture(work)
        (source / "pkg/afl/vendor").mkdir(parents=True)
        (source / "pkg/afl/vendor/afl.c").write_text("int g(void) { return 1; }\n")
        (source / "pkg/afl/LICENSE").write_text("Apache-2.0 text\n")
        result = run(
            COLLECTOR, "--ghostty-source", source, "--zig-cache", cache,
            "--output", work / "collected", "--revision", REVISION,
        )
        assert result.returncode == 0, result.stderr


def test_pinned_vendored_texts_ship_with_the_tree() -> None:
    """simdutf: the reviewed amalgamation ships the pinned simdutf texts
    (Apache-2.0, MIT and the PyTorch BSD-3 notice); another version fails."""
    content = b"/* simdutf amalgamation fixture */\n"
    with tempfile.TemporaryDirectory(prefix="cmux-ghostty-vendored-") as raw:
        work = Path(raw)
        pinned = work / "pinned"
        shutil.copytree(PINNED, pinned)
        manifest = json.loads((pinned / "MANIFEST.json").read_text())
        manifest["vendored"]["pkg/simdutf"]["files"] = {
            "vendor/simdutf.cpp": hashlib.sha256(content).hexdigest(),
        }
        (pinned / "MANIFEST.json").write_text(json.dumps(manifest))
        source, cache = build_fixture(work)
        (source / "pkg/simdutf/vendor").mkdir(parents=True)
        (source / "pkg/simdutf/vendor/simdutf.cpp").write_bytes(content)
        output = work / "collected"
        assert collect_in_process(source, cache, output, pinned=pinned, accept_manifest=True) == 0
        collected = json.loads((output / "SOURCE-MANIFEST.json").read_text())
        shipped = {
            entry["source"]: entry for entry in collected["license_files"]
            if entry["package"] == "pkg/simdutf"
        }
        for item in manifest["packages"]["simdutf"]["files"]:
            entry = shipped[item["upstream"]]
            assert entry["source_kind"] == "verified-upstream-license"
            assert (output / entry["destination"]).read_bytes() == (pinned / item["path"]).read_bytes()
        verified = run(VERIFIER, "--root", output, "--revision", REVISION)
        assert verified.returncode == 0, verified.stderr
        other = work / "other"
        other.mkdir()
        source, cache = build_fixture(other)
        (source / "pkg/simdutf/vendor").mkdir(parents=True)
        (source / "pkg/simdutf/vendor/simdutf.cpp").write_bytes(content + b"// 9.1.0\n")
        assert collect_in_process(
            source, cache, other / "collected", pinned=pinned, accept_manifest=True
        ) != 0


def test_verifier_rejects_long_destination() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-ghostty-path-budget-") as raw:
        work = Path(raw)
        source, cache = build_fixture(work)
        output = work / "collected"
        assert (
            run(
                COLLECTOR,
                "--ghostty-source",
                source,
                "--zig-cache",
                cache,
                "--output",
                output,
                "--revision",
                REVISION,
            ).returncode
            == 0
        )
        manifest_path = output / "SOURCE-MANIFEST.json"
        manifest = json.loads(manifest_path.read_text())
        entry = manifest["license_files"][0]
        long_name = "x" * (MAX_DESTINATION_CHARS + 1 - len("ghostty-source/"))
        long_destination = f"ghostty-source/{long_name}"
        assert len(long_destination) == MAX_DESTINATION_CHARS + 1
        (output / long_destination).write_bytes(
            (output / entry["destination"]).read_bytes()
        )
        (output / entry["destination"]).unlink()
        entry["destination"] = long_destination
        manifest_path.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        )
        rejected = run(VERIFIER, "--root", output, "--revision", REVISION)
        assert rejected.returncode != 0
        assert "extraction budget" in rejected.stderr, rejected.stderr


def test_collector_rejects_label_collision() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-ghostty-path-budget-") as raw:
        work = Path(raw)
        source, cache = build_fixture(work)
        first = cache / "p/N-V-__8AAG02ugUcSAMEPREFIX-one"
        second = cache / "p/N-V-__8AAG02ugUcSAMEPREFIX-two"
        for package in (first, second):
            package.mkdir(parents=True)
            (package / "LICENSE").write_text("collision fixture\n")
        result = run(
            COLLECTOR,
            "--ghostty-source",
            source,
            "--zig-cache",
            cache,
            "--output",
            work / "collected",
            "--revision",
            REVISION,
        )
        assert result.returncode != 0
        assert "label collision" in result.stderr, result.stderr


def test_pinned_manifest_digest_matches_the_collector() -> None:
    spec = importlib.util.spec_from_file_location("ghostty_collector_digest", COLLECTOR)
    assert spec is not None and spec.loader is not None
    collector = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(collector)
    digest = hashlib.sha256((PINNED / "MANIFEST.json").read_bytes()).hexdigest()
    assert digest == collector.PINNED_MANIFEST_SHA256, digest


def test_collector_requires_a_release_source_offer() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-ghostty-path-budget-") as raw:
        work = Path(raw)
        source, cache = build_fixture(work)
        result = subprocess.run(
            [sys.executable, str(COLLECTOR), "--ghostty-source", str(source),
             "--zig-cache", str(cache), "--output", str(work / "collected"),
             "--revision", REVISION],
            check=False, capture_output=True, text=True,
        )
        assert result.returncode != 0
        assert "--release-source-offer" in result.stderr, result.stderr


def main() -> int:
    test_pinned_manifest_digest_matches_the_collector()
    test_collector_requires_a_release_source_offer()
    test_bounded_round_trip()
    test_zig_package_index()
    test_zig_pkg_package_without_license_is_unresolved()
    test_vendored_directory_without_license_is_unresolved()
    test_vendored_directory_with_a_license_file_is_covered()
    test_pinned_vendored_texts_ship_with_the_tree()
    test_known_zig_pkg_licenses()
    test_themes_and_gobject_get_pinned_texts()
    test_ghostty_next_packages_get_pinned_texts()
    test_verifier_rejects_long_destination()
    test_collector_rejects_label_collision()
    print("Ghostty license path budget tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
