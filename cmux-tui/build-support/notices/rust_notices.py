#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Third-party notices for the Rust crates that one binary links.

Shared by manaflow-ai/cmux (cmux-next app bundle) and manaflow-ai/cmux-browser
(which copies cmux-tui/build-support at its cmux-tui.pin). Python 3.11+
standard library only; cargo is optional.

Modules: cargo_inputs.py (Cargo.lock, cfg(), manifests, source directories),
notice_model.py (data types), notice_render.py (SPDX, markdown, file tree).
Helpers: fetch_crates.py fills a CARGO_HOME-shaped source cache without
cargo; fetch_reviewed_text.py stores upstream texts for crates that ship none.

Closure. The tool walks Cargo.lock from each --root package and keeps an edge
only when the dependent's Cargo.toml declares the dependency as a normal
dependency (not dev-dependencies, not build-dependencies) that applies to
--target (a `[target.'cfg(...)'.dependencies]` table whose cfg is false for
the target is dropped; an unknown cfg term counts as true). --target is
repeatable; the closure is then the union (a universal binary). Proc-macro crates
are dropped: the binary does not link them. An optional dependency stays when
the lock records the edge; Cargo.lock unifies features over the whole
workspace, so this "text" closure can list a crate that this binary does not
link (conservative). With --cargo-tree FILE (the output of
`cargo tree -p ROOT -e normal --target TRIPLE --prefix none -f "{p}"`, made
where cargo runs) the closure is exact; the tool fails when that set is not a
subset of the text closure.

Texts. Every license text is the verbatim bytes of a file in the crate's
source: top-level LICENSE*/LICENCE*/COPYING*/NOTICE*/UNLICENSE*/COPYRIGHT*
files, the manifest `license-file`, and extra files that --reviewed names; a
git crate without its own files takes the checkout root's (repository-*). A
crate with no text and no reviewed text fails the run. A text that is not
UTF-8 fails the run (it is never re-encoded). The tool never writes license
text of its own. A `cargo vendor` directory must carry the Cargo.lock checksum
in .cargo-checksum.json.

downloadLocation: crates.io download URL; git sources as SPDX VCS form
git+URL@REV; first-party path crates as the permanent source tag
https://github.com/manaflow-ai/cmux/tree/<--source-tag>/<path>.

Outputs are deterministic (sorted, no timestamp unless --created is given):
  --format spdx-json  SPDX 2.3 JSON; one package per crate (name = prefix +
                      crate name, versionInfo = version), one file entry per
                      license file (fileName = <crate>-<version>/<file>, SHA256)
  --format markdown   one notices section for an app bundle
  --files-out DIR     the license files, as DIR/<crate>-<version>/<file>
                      (DIR then holds exactly these files)
  --check             regenerate and fail when --out or --files-out differ

--reviewed JSON (owned by the license review):
  {"extra_license_files": {"<name>" | "<name> <version>": ["AUTHORS", ...]},
   "license_texts": {"<name> <version>": {"reason": "...", "files": [
                     {"file": "<path relative to the JSON>",
                      "source": "<upstream URL at a fixed commit>",
                      "sha256": "<digest of the stored file>"}]}},
   "elections": {"<name>" | "<name> <version>":
                 {"declared": "<manifest expression>", "concluded": "MIT",
                  "reason": "..."}}}
An election fails the run when the manifest expression differs from
"declared" or when "concluded" is not one of its top-level OR alternatives.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from typing import Iterable

from cargo_inputs import Manifest, Sources, parse_cargo_tree, read_lock, read_manifest, target_info
from notice_model import (
    CRATES_IO,
    LICENSE_FILE,
    Crate,
    Key,
    LicenseFile,
    LockPackage,
    NoticeError,
    or_alternatives,
    slug,
    spdx_expression,
)
from notice_render import render_markdown, render_spdx, tree_digest, write_files


# Reviewed data ----------------------------------------------------------------


@dataclasses.dataclass
class Reviewed:
    base: Path
    extra_files: dict[str, list[str]]
    texts: dict[str, dict]
    elections: dict[str, dict]

    @classmethod
    def load(cls, path: Path | None) -> "Reviewed":
        if path is None:
            return cls(Path("."), {}, {}, {})
        data = json.loads(path.read_text(encoding="utf-8"))
        allowed = {"extra_license_files", "extra_license_reasons", "skipped_license_files", "license_texts", "elections", "comment"}
        unknown = set(data) - allowed
        if unknown:
            raise NoticeError(f"{path}: unknown keys {sorted(unknown)}")
        return cls(path.parent, data.get("extra_license_files", {}), data.get("license_texts", {}), data.get("elections", {}))

    @staticmethod
    def lookup(table: dict, key: Key):
        return table.get(f"{key.name} {key.version}", table.get(key.name))


def resolve_closure(
    lock: dict[Key, LockPackage],
    roots: list[str],
    targets: list[dict],
    sources: Sources,
) -> tuple[dict[Key, set[str]], dict[Key, Manifest], dict[Key, tuple[Path, Path | None]]]:
    """Union of the closures for every target (a universal binary links both)."""
    manifests: dict[Key, Manifest] = {}
    locations: dict[Key, tuple[Path, Path | None]] = {}
    reached: dict[Key, set[str]] = {}
    for target in targets:
        per_target: dict[Key, Manifest] = {}

        def manifest(key: Key) -> Manifest:
            if key not in per_target:
                if key not in locations:
                    locations[key] = sources.locate(lock[key])
                location = locations[key]
                per_target[key] = read_manifest(location[0] / "Cargo.toml", target, sources.workspace_for(location[0]))
                manifests.setdefault(key, per_target[key])
            return per_target[key]

        _walk(lock, roots, manifest, reached)
    return reached, manifests, locations


def _walk(lock: dict[Key, LockPackage], roots: list[str], manifest, reached: dict[Key, set[str]]) -> None:
    for root_name in roots:
        root_keys = [k for k in lock if k.name == root_name]
        if len(root_keys) != 1:
            raise NoticeError(f"--root {root_name}: {len(root_keys)} lock packages with that name")
        stack = [root_keys[0]]
        seen = {root_keys[0]}
        while stack:
            key = stack.pop()
            reached.setdefault(key, set()).add(root_name)
            owner = manifest(key)
            for dep in lock[key].deps:
                if dep.name not in owner.normal or dep in seen:
                    continue
                if manifest(dep).proc_macro:
                    continue
                seen.add(dep)
                stack.append(dep)


def collect(args: argparse.Namespace) -> list[Crate]:
    targets = [target_info(t) for t in args.target or ["aarch64-apple-darwin"]]
    lock = read_lock(args.lock)
    sources = Sources(args.sources, args.workspace)
    reviewed = Reviewed.load(args.reviewed)
    reached, manifests, locations = resolve_closure(lock, args.root, targets, sources)
    closure_label = "lock text"
    if args.cargo_tree:
        exact: set[Key] = set()
        for tree in args.cargo_tree:
            exact |= parse_cargo_tree(tree)
        missing = sorted(exact - set(reached))
        if missing:
            raise NoticeError("cargo tree lists crates outside the lock text closure: " + ", ".join(f"{k.name} {k.version}" for k in missing))
        reached = {k: v for k, v in reached.items() if k in exact}
        closure_label = "exact (cargo tree)"
    first_party_license = args.first_party_license.read_bytes() if args.first_party_license else None
    errors: list[str] = []
    crates: list[Crate] = []
    for key in sorted(reached):
        crate_dir, ws_root = locations[key]
        package = manifests[key].package
        base = args.repo_root.resolve() if args.repo_root else (ws_root.resolve() if ws_root else None)
        rel = crate_dir.resolve().relative_to(base).as_posix() if ws_root and base and crate_dir.resolve().is_relative_to(base) else None
        first_party = rel is not None and any(Path(rel).match(g) for g in args.first_party)
        declared = spdx_expression(package.get("license"))
        files: list[LicenseFile] = []
        if first_party:
            if first_party_license is None:
                errors.append(f"{key.name}: first-party crate needs --first-party-license")
                continue
            files.append(LicenseFile(args.first_party_license_name, first_party_license))
            if args.source_tag is None:
                errors.append("first-party crates need --source-tag")
                continue
            prefix = "" if args.repo_root else args.source_tag_path_prefix.rstrip("/")
            download = f"https://github.com/manaflow-ai/cmux/tree/{args.source_tag}/{prefix + '/' if prefix else ''}{rel}"
        else:
            names = sorted(p.name for p in crate_dir.iterdir() if p.is_file() and LICENSE_FILE.match(p.name))
            license_file = package.get("license-file")
            if license_file and license_file not in names:
                names.append(license_file)
            names += [n for n in Reviewed.lookup(reviewed.extra_files, key) or [] if n not in names]
            for name in sorted(names):
                path = crate_dir / name
                if not path.is_file():
                    errors.append(f"{key.name} {key.version}: license file {name} is missing")
                    continue
                files.append(LicenseFile(name, path.read_bytes()))
            checkout = sources.git_checkout_root(crate_dir)
            if not files and checkout is not None and checkout != crate_dir.resolve():
                # A git crate inside a workspace: cargo package would copy the
                # repository's license files; a git checkout keeps them at its root.
                for path in sorted(checkout.iterdir()):
                    if path.is_file() and LICENSE_FILE.match(path.name):
                        files.append(LicenseFile(f"repository-{path.name}", path.read_bytes()))
            text = Reviewed.lookup(reviewed.texts, key)
            for entry in (text or {}).get("files", []):
                data = (reviewed.base / entry["file"]).read_bytes()
                if hashlib.sha256(data).hexdigest() != entry.get("sha256"):
                    errors.append(f"{key.name} {key.version}: reviewed text {entry['file']} does not match its sha256")
                    continue
                files.append(LicenseFile(f"reviewed-{Path(entry['file']).name}", data))
            source = lock[key].source
            if source == CRATES_IO:
                download = f"https://crates.io/api/v1/crates/{key.name}/{key.version}/download"
            elif source and source.startswith("git+"):
                url, _, rev = source[4:].partition("#")
                download = f"git+{url.split('?')[0]}@{rev}"
            elif source is None and args.repo_root and rel is not None and args.source_tag:
                # A vendored third-party path crate inside manaflow-ai/cmux.
                download = f"https://github.com/manaflow-ai/cmux/tree/{args.source_tag}/{rel}"
            elif source is None and args.path_download:
                download = args.path_download
            else:
                download = "NOASSERTION"
        if not files:
            errors.append(f"{key.name} {key.version}: no license file in {crate_dir} and no reviewed text")
            continue
        if declared is None:
            declared = f"LicenseRef-{slug(key.name)}-{slug(key.version)}"
        concluded = declared
        election = Reviewed.lookup(reviewed.elections, key)
        if election is not None:
            if election.get("declared") != declared:
                errors.append(f"{key.name} {key.version}: election expects declared {election.get('declared')!r}, manifest says {declared!r}")
                continue
            concluded = election["concluded"]
            if concluded not in or_alternatives(declared):
                errors.append(f"{key.name} {key.version}: election concludes {concluded!r}, which is not one of the alternatives of {declared!r}")
                continue
        crates.append(Crate(key, first_party, declared, concluded, download, lock[key].checksum, files, closure_label, sorted(reached[key])))
    if errors:
        raise NoticeError("\n".join(errors))
    return crates


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--lock", type=Path, required=True)
    p.add_argument("--lock-label", help="lock path to print in the markdown header (default: file name)")
    p.add_argument("--root", action="append", required=True, help="package that is linked into the binary (repeatable)")
    p.add_argument("--target", action="append", help="target triple (repeatable; the closure is the union; default aarch64-apple-darwin)")
    p.add_argument("--sources", type=Path, action="append", default=[], help="cargo vendor or registry src directory (repeatable)")
    p.add_argument("--workspace", type=Path, action="append", default=[], help="workspace root that holds path packages (repeatable)")
    p.add_argument("--first-party", action="append", default=[], help="glob of first-party path packages, relative to --repo-root (else to the package's workspace)")
    p.add_argument("--repo-root", type=Path, help="manaflow-ai/cmux checkout root: first-party globs and source-tag paths are relative to it")
    p.add_argument("--first-party-license", type=Path, help="license file for first-party crates (copied verbatim)")
    p.add_argument("--first-party-license-name", default="LICENSE")
    p.add_argument("--source-tag", help="permanent source tag for first-party downloadLocation, e.g. cmux-tui-src-b8feb806d6e")
    p.add_argument("--source-tag-path-prefix", default="cmux-tui", help="path of the workspace inside manaflow-ai/cmux (ignored with --repo-root)")
    p.add_argument("--path-download", help="downloadLocation for third-party path packages (e.g. git+URL@REV of the checkout given with --workspace)")
    p.add_argument("--reviewed", type=Path)
    p.add_argument("--cargo-tree", type=Path, action="append")
    p.add_argument("--format", choices=("spdx-json", "markdown"), default="spdx-json")
    p.add_argument("--spdx-prefix", default="")
    p.add_argument("--spdx-id-prefix", default="SPDXRef-")
    p.add_argument("--section-id", default="rust")
    p.add_argument("--title", default="Rust crates")
    p.add_argument("--created", default="1970-01-01T00:00:00Z")
    p.add_argument("--out", type=Path)
    p.add_argument("--files-out", type=Path)
    p.add_argument("--check", action="store_true")
    return p.parse_args(list(argv))


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    try:
        crates = collect(args)
        text = render_spdx(crates, args) if args.format == "spdx-json" else render_markdown(crates, args)
    except NoticeError as error:
        print(f"rust_notices: error: {error}", file=sys.stderr)
        return 1
    if args.check:
        stale = []
        if args.out and (not args.out.is_file() or args.out.read_text(encoding="utf-8") != text):
            stale.append(str(args.out))
        if args.files_out:
            with tempfile.TemporaryDirectory() as tmp:
                write_files(crates, Path(tmp))
                if not args.files_out.is_dir() or tree_digest(Path(tmp)) != tree_digest(args.files_out):
                    stale.append(str(args.files_out))
        if stale:
            print("rust_notices: stale: " + ", ".join(stale), file=sys.stderr)
            return 1
        return 0
    try:
        if args.files_out:
            write_files(crates, args.files_out)
    except NoticeError as error:
        print(f"rust_notices: error: {error}", file=sys.stderr)
        return 1
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
