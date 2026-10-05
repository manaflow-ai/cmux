#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Notices for the Rust and Zig standard libraries that bundled binaries link.

  toolchain_notices.py check-repo [--repo DIR]   texts match toolchains.json;
                                                 the toolchain pins match it
  toolchain_notices.py install --resources DIR   copy the texts to
                                                 DIR/toolchain-licenses/

Every Rust binary statically links the standard library (std, core, alloc,
compiler_builtins and their vendored dependencies) of the rustc that built
it. Rust publishes those notices per release as COPYRIGHT-library.html in the
rustc component (share/doc/rust/COPYRIGHT-library.html; the file is the same
for every host target). Zig binaries and static libraries link Zig's std and
compiler_rt, under Zig's MIT (Expat) LICENSE.

toolchains.json (owned by the license review) records, per toolchain, the
stored text (texts/<file>), its sha256 and where it came from:
  rust: version, rustc_commit (the `/rustc/<commit>/` prefix of std paths
        inside a binary), toolchain_files (rust-toolchain.toml files whose
        channel must equal version), binaries (a note)
  zig:  version, ghostty_sources (submodules whose build.zig.zon
        minimum_zig_version must equal version), binaries (a note)
check-repo fails when a pin moves, so a toolchain bump stops until the new
text is reviewed and recorded. A missing build.zig.zon fails (initialize the
submodule); nothing is skipped.

check_bundle_notices.py uses rust_std_problems (bundle-map requirement
`rust-std`: every rustc commit named inside the Mach-O must be a reviewed
toolchain whose text is bundled unchanged) and zig_std_problems (`zig-std`).
bundle-cli-resources.sh (the Xcode phase) runs `install`.

Python 3.9+ standard library only: the Xcode phase may run /usr/bin/python3.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
from typing import List, Optional

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "toolchains.json"
TEXTS = HERE / "texts"
RUSTC_PATH = re.compile(rb"/rustc/([0-9a-f]{40})/")
CHANNEL = re.compile(r'^\s*channel\s*=\s*"([^"]+)"', re.M)
ZIG_MINIMUM = re.compile(r'^\s*\.minimum_zig_version\s*=\s*"([^"]+)"', re.M)
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


class ManifestError(RuntimeError):
    pass


class Text:
    KEYS = {"version", "file", "sha256", "source", "binaries"}

    def __init__(self, data: dict, texts: Path, extra: set):
        unknown = set(data) - self.KEYS - extra
        missing = (self.KEYS | extra) - set(data)
        if unknown or missing:
            raise ManifestError(f"toolchains.json entry {data.get('version')!r}: unknown keys {sorted(unknown)}, missing keys {sorted(missing)}")
        if not VERSION.match(data["version"]):
            raise ManifestError(f"toolchains.json: bad version {data['version']!r}")
        if not re.fullmatch(r"[0-9a-f]{64}", data["sha256"]):
            raise ManifestError(f"toolchains.json {data['version']}: bad sha256")
        if Path(data["file"]).is_absolute() or ".." in Path(data["file"]).parts:
            raise ManifestError(f"toolchains.json {data['version']}: file must be relative to texts/")
        self.version: str = data["version"]
        self.file: str = data["file"]
        self.sha256: str = data["sha256"]
        self.source: str = data["source"]
        self.path = texts / self.file

    def problem(self) -> Optional[str]:
        if not self.path.is_file():
            return f"{self.file}: stored text is missing"
        if hashlib.sha256(self.path.read_bytes()).hexdigest() != self.sha256:
            return f"{self.file}: stored text does not match its sha256 in toolchains.json"
        return None


class RustToolchain(Text):
    def __init__(self, data: dict, texts: Path):
        super().__init__(data, texts, {"rustc_commit", "toolchain_files"})
        if not re.fullmatch(r"[0-9a-f]{40}", data["rustc_commit"]):
            raise ManifestError(f"toolchains.json rust {data['version']}: rustc_commit must be 40 hex digits")
        self.rustc_commit: str = data["rustc_commit"]
        self.toolchain_files: List[str] = list(data["toolchain_files"])


class ZigToolchain(Text):
    def __init__(self, data: dict, texts: Path):
        super().__init__(data, texts, {"ghostty_sources"})
        self.ghostty_sources: List[str] = list(data["ghostty_sources"])


class Manifest:
    def __init__(self, bundle_dir: str, rust: List[RustToolchain], zig: List[ZigToolchain]):
        self.bundle_dir = bundle_dir
        self.rust = rust
        self.zig = zig

    @classmethod
    def from_dict(cls, data: dict, texts: Path = TEXTS) -> "Manifest":
        unknown = set(data) - {"comment", "bundle_dir", "rust", "zig"}
        if unknown:
            raise ManifestError(f"toolchains.json: unknown keys {sorted(unknown)}")
        rust = [RustToolchain(e, texts) for e in data["rust"]]
        zig = [ZigToolchain(e, texts) for e in data["zig"]]
        commits = [r.rustc_commit for r in rust]
        if len(set(commits)) != len(commits):
            raise ManifestError("toolchains.json: two rust entries name one rustc_commit")
        return cls(data["bundle_dir"], rust, zig)

    def texts(self) -> List[Text]:
        return [*self.rust, *self.zig]


def load(path: Path = MANIFEST) -> Manifest:
    return Manifest.from_dict(json.loads(path.read_text(encoding="utf-8")), path.parent / "texts")


# Repository ----------------------------------------------------------------------


def text_problems(manifest: Manifest) -> List[str]:
    return [p for p in (t.problem() for t in manifest.texts()) if p]


def rust_toolchain_problems(manifest: Manifest, root: Path) -> List[str]:
    problems = []
    for rust in manifest.rust:
        for rel in rust.toolchain_files:
            path = root / rel
            match = CHANNEL.search(path.read_text(encoding="utf-8")) if path.is_file() else None
            channel = match.group(1) if match else None
            if channel != rust.version:
                problems.append(
                    f"{rel}: channel {channel!r}, but toolchains.json ships the {rust.version} COPYRIGHT-library.html "
                    f"for it; review that rustc's share/doc/rust/COPYRIGHT-library.html and record it in "
                    f"cmux-tui/build-support/notices/toolchains/toolchains.json"
                )
    return problems


def zig_toolchain_problems(manifest: Manifest, root: Path) -> List[str]:
    problems = []
    for zig in manifest.zig:
        for source in zig.ghostty_sources:
            rel = f"{source}/build.zig.zon"
            path = root / rel
            if not path.is_file():
                problems.append(f"{rel}: missing; run `git submodule update --init {source}` (the Zig notice is tied to its minimum_zig_version)")
                continue
            match = ZIG_MINIMUM.search(path.read_text(encoding="utf-8"))
            found = match.group(1) if match else None
            if found != zig.version:
                problems.append(
                    f"{rel}: minimum_zig_version {found!r}, but toolchains.json ships the Zig {zig.version} LICENSE "
                    f"for it; review that Zig's LICENSE and record it in cmux-tui/build-support/notices/toolchains/toolchains.json"
                )
    return problems


def repo_problems(manifest: Manifest, root: Path) -> List[str]:
    return text_problems(manifest) + rust_toolchain_problems(manifest, root) + zig_toolchain_problems(manifest, root)


# Bundle ---------------------------------------------------------------------------


def install(manifest: Manifest, resources: Path) -> Path:
    """Copy every stored text to <resources>/toolchain-licenses (replaced)."""
    problems = text_problems(manifest)
    if problems:
        raise ManifestError("; ".join(problems))
    dest = resources / Path(manifest.bundle_dir).name
    if dest.exists():
        shutil.rmtree(dest)
    for text in manifest.texts():
        target = dest / text.file
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(text.path, target)
    return dest


def _bundled_problem(manifest: Manifest, app: Path, text: Text) -> Optional[str]:
    rel = f"{manifest.bundle_dir}/{text.file}"
    path = app / rel
    if not path.is_file():
        return f"{rel} is not bundled"
    if hashlib.sha256(path.read_bytes()).hexdigest() != text.sha256:
        return f"{rel} differs from the reviewed text"
    return None


def rustc_commits(path: Path) -> List[str]:
    """The rustc commits whose std paths (`/rustc/<commit>/...`) a binary names."""
    return sorted({m.decode() for m in RUSTC_PATH.findall(path.read_bytes())})


def rust_std_problems(manifest: Manifest, app: Path, binary: str) -> List[str]:
    commits = rustc_commits(app / binary)
    if not commits:
        return [f"no /rustc/<commit>/ path inside {binary}; cannot tell which Rust standard library it links"]
    by_commit = {r.rustc_commit: r for r in manifest.rust}
    problems = []
    for commit in commits:
        rust = by_commit.get(commit)
        if rust is None:
            problems.append(f"links the standard library of rustc {commit}, which toolchains.json does not review")
            continue
        problem = _bundled_problem(manifest, app, rust)
        if problem:
            problems.append(f"Rust {rust.version}: {problem}")
    return problems


def zig_std_problems(manifest: Manifest, app: Path) -> List[str]:
    problems = []
    for zig in manifest.zig:
        problem = _bundled_problem(manifest, app, zig)
        if problem:
            problems.append(f"Zig {zig.version}: {problem}")
    return problems


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    repo = sub.add_parser("check-repo")
    repo.add_argument("--repo", type=Path, default=HERE.parents[3])
    inst = sub.add_parser("install")
    inst.add_argument("--resources", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        manifest = load()
        if args.command == "install":
            dest = install(manifest, args.resources)
            print(f"toolchain_notices: installed {len(manifest.texts())} texts into {dest}")
            return 0
        problems = repo_problems(manifest, args.repo)
    except ManifestError as error:
        print(f"toolchain_notices: error: {error}", file=sys.stderr)
        return 1
    for problem in problems:
        print(f"toolchain_notices: error: {problem}", file=sys.stderr)
    if problems:
        return 1
    print("toolchain_notices: Rust and Zig standard library notices match the toolchain pins")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
