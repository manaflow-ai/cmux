#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Third-party notices for the Rust crates that one binary links.

Shared by manaflow-ai/cmux (cmux-next app bundle) and manaflow-ai/cmux-browser
(which copies cmux-tui/build-support at its cmux-tui.pin). Python 3.11+
standard library only; cargo is optional.

Closure. The tool walks Cargo.lock from each --root package and keeps an edge
only when the dependent's Cargo.toml declares the dependency as a normal
dependency (not dev-dependencies, not build-dependencies) that applies to
--target (a `[target.'cfg(...)'.dependencies]` table whose cfg is false for
the target is dropped; an unknown cfg term counts as true). Proc-macro crates
are dropped: the binary does not link them. An optional dependency stays when
the lock records the edge; Cargo.lock unifies features over the whole
workspace, so this "text" closure can list a crate that this binary does not
link (conservative). With --cargo-tree FILE (the output of
`cargo tree -p ROOT -e normal --target TRIPLE --prefix none -f "{p}"`, made
where cargo runs) the closure is exact; the tool fails when that set is not a
subset of the text closure.

Texts. Every license text is the verbatim bytes of a file in the crate's
source: top-level LICENSE*/LICENCE*/COPYING*/NOTICE*/UNLICENSE*/COPYRIGHT*
files, the manifest `license-file`, and extra files that --reviewed names. A
crate with no text and no reviewed text fails the run. The tool never writes
license text of its own.

Outputs are deterministic (sorted, no timestamp unless --created is given):
  --format spdx-json  SPDX 2.3 JSON; one package per crate (name = prefix +
                      crate name, versionInfo = version), one file entry per
                      license file (fileName = <crate>-<version>/<file>, SHA256)
  --format markdown   one notices section for an app bundle
  --files-out DIR     the license files, as DIR/<crate>-<version>/<file>
  --check             regenerate and fail when --out or --files-out differ

--reviewed JSON (owned by the license review):
  {"extra_license_files": {"<name>" | "<name> <version>": ["AUTHORS", ...]},
   "license_texts": {"<name> <version>": {"reason": "...", "file": "<path
                     relative to the JSON>"}},
   "elections": {"<name>" | "<name> <version>":
                 {"declared": "<manifest expression>", "concluded": "MIT",
                  "reason": "..."}}}
An election fails the run when the manifest expression differs from
"declared".
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import tomllib
from typing import Iterable

CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"
LICENSE_FILE = re.compile(
    r"^(LICEN[CS]E|COPYING|NOTICE|UNLICENSE|COPYRIGHT)([-._].*)?$", re.I
)
TOOL = "rust_notices.py"


class NoticeError(RuntimeError):
    pass


# Cargo.lock -----------------------------------------------------------------


@dataclasses.dataclass(frozen=True, order=True)
class Key:
    name: str
    version: str


@dataclasses.dataclass
class LockPackage:
    key: Key
    source: str | None
    checksum: str | None
    deps: list[Key]


def read_lock(path: Path) -> dict[Key, LockPackage]:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    raw = data.get("package", [])
    by_name: dict[str, list[dict]] = {}
    for item in raw:
        by_name.setdefault(item["name"], []).append(item)
    packages: dict[Key, LockPackage] = {}
    for item in raw:
        key = Key(item["name"], item["version"])
        deps = []
        for spec in item.get("dependencies", []):
            parts = spec.split(" ")
            candidates = by_name.get(parts[0], [])
            if len(parts) >= 2:
                candidates = [c for c in candidates if c["version"] == parts[1]]
            if len(parts) >= 3:
                source = parts[2].strip("()")
                candidates = [c for c in candidates if c.get("source") == source]
            if len(candidates) != 1:
                raise NoticeError(f"{path}: cannot resolve dependency {spec!r} of {key.name}")
            deps.append(Key(candidates[0]["name"], candidates[0]["version"]))
        packages[key] = LockPackage(key, item.get("source"), item.get("checksum"), deps)
    return packages


# cfg() evaluation (three-valued: True, False, None = unknown) -----------------

TARGETS: dict[str, dict[str, object]] = {}


def _target(triple: str) -> dict[str, object]:
    arch, _, rest = triple.partition("-")
    vendor, _, os_env = rest.partition("-")
    if vendor in ("apple",):
        osname = "ios" if "ios" in os_env else "macos"
        env = "sim" if os_env.endswith("-sim") else ""
    elif os_env.startswith("linux"):
        osname, env = "linux", os_env.partition("-")[2] or "gnu"
    elif os_env.startswith("windows"):
        osname, env = "windows", os_env.partition("-")[2] or "msvc"
    else:
        raise NoticeError(f"unsupported --target {triple}")
    family = "windows" if osname == "windows" else "unix"
    arch = {"arm64": "aarch64"}.get(arch, arch)
    return {
        "target_arch": arch,
        "target_os": osname,
        "target_vendor": "pc" if osname == "windows" else ("apple" if vendor == "apple" else "unknown"),
        "target_env": env,
        "target_family": family,
        "target_pointer_width": "64",
        "target_endian": "little",
        "flags": {family},
        "triple": triple,
    }


def _tokens(text: str) -> list[str]:
    return re.findall(r'"[^"]*"|[A-Za-z_][A-Za-z0-9_]*|[(),=]', text)


def eval_cfg(text: str, target: dict[str, object]) -> bool | None:
    text = text.strip()
    if not text.startswith("cfg("):
        return text == target["triple"]
    tokens = _tokens(text[4:-1])
    pos = 0

    def parse() -> bool | None:
        nonlocal pos
        word = tokens[pos]
        pos += 1
        if word in ("all", "any", "not") and pos < len(tokens) and tokens[pos] == "(":
            pos += 1
            values = []
            while tokens[pos] != ")":
                values.append(parse())
                if tokens[pos] == ",":
                    pos += 1
            pos += 1
            if word == "not":
                return None if values[0] is None else not values[0]
            if word == "all":
                if any(v is False for v in values):
                    return False
                return None if any(v is None for v in values) else True
            if any(v is True for v in values):
                return True
            return None if any(v is None for v in values) else False
        if pos < len(tokens) and tokens[pos] == "=":
            value = tokens[pos + 1].strip('"')
            pos += 2
            if word in target:
                return target[word] == value
            if word == "target_has_atomic":
                return value in ("8", "16", "32", "64", "ptr")
            return None
        if word in ("unix", "windows"):
            return word in target["flags"]  # type: ignore[operator]
        if word in ("test", "miri", "doc", "doctest", "loom", "fuzzing", "kani"):
            return False
        return None

    return parse()


# Manifests -------------------------------------------------------------------


@dataclasses.dataclass
class Manifest:
    path: Path
    package: dict
    normal: set[str]  # package names linked for the target (cfg not false)
    proc_macro: bool


def _dep_package_name(name: str, spec: object, workspace_deps: dict) -> str:
    if isinstance(spec, dict):
        if spec.get("workspace") is True:
            ws = workspace_deps.get(name, {})
            if isinstance(ws, dict) and "package" in ws:
                return ws["package"]
        if "package" in spec:
            return spec["package"]
    return name


def read_manifest(path: Path, target: dict, workspace: dict | None) -> Manifest:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    workspace_deps = (workspace or {}).get("dependencies", {})
    normal: set[str] = set()
    for name, spec in data.get("dependencies", {}).items():
        normal.add(_dep_package_name(name, spec, workspace_deps))
    for cfg, table in sorted(data.get("target", {}).items()):
        if eval_cfg(cfg, target) is False:
            continue
        for name, spec in table.get("dependencies", {}).items():
            normal.add(_dep_package_name(name, spec, workspace_deps))
    package = dict(data.get("package", {}))
    for field in ("license", "license-file", "repository", "version"):
        value = package.get(field)
        if isinstance(value, dict) and value.get("workspace") is True:
            package[field] = (workspace or {}).get("package", {}).get(field)
    proc_macro = bool(data.get("lib", {}).get("proc-macro", False))
    return Manifest(path, package, normal, proc_macro)


# Sources ---------------------------------------------------------------------


class Sources:
    def __init__(self, dirs: list[Path], workspaces: list[Path]):
        self.dirs = list(dirs)
        cargo_home = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo"))
        self.dirs += sorted((cargo_home / "registry" / "src").glob("*"))
        self.git_dirs = sorted((cargo_home / "git" / "checkouts").glob("*/*"))
        self.path_packages: dict[str, list[tuple[Path, Path]]] = {}
        self.workspace_tables: dict[Path, dict] = {}
        for root in workspaces:
            root_manifest = root / "Cargo.toml"
            ws = tomllib.loads(root_manifest.read_text(encoding="utf-8")).get("workspace")
            self.workspace_tables[root.resolve()] = ws or {}
            for manifest in sorted(root.rglob("Cargo.toml")):
                if any(part in ("target", ".git", "node_modules") for part in manifest.relative_to(root).parts):
                    continue
                try:
                    name = tomllib.loads(manifest.read_text(encoding="utf-8")).get("package", {}).get("name")
                except tomllib.TOMLDecodeError:
                    continue
                if name:
                    self.path_packages.setdefault(name, []).append((manifest.parent, root))

    def workspace_for(self, crate_dir: Path) -> dict | None:
        for root, table in self.workspace_tables.items():
            if crate_dir.resolve().is_relative_to(root):
                return table
        return None

    def locate(self, package: LockPackage) -> tuple[Path, Path | None]:
        """(crate directory, workspace root for path packages)."""
        key = package.key
        if package.source is None:
            matches = [
                (d, root)
                for d, root in self.path_packages.get(key.name, [])
                if _manifest_version(d, self) == key.version
            ]
            if len(matches) != 1:
                raise NoticeError(f"path package {key.name} {key.version}: {len(matches)} matching manifests under --workspace")
            return matches[0]
        if package.source.startswith("git+"):
            rev = package.source.rsplit("#", 1)[-1]
            for base in self.git_dirs:
                if not rev.startswith(base.name):
                    continue
                for manifest in sorted(base.rglob("Cargo.toml")):
                    try:
                        pkg = tomllib.loads(manifest.read_text(encoding="utf-8")).get("package", {})
                    except tomllib.TOMLDecodeError:
                        continue
                    if pkg.get("name") == key.name:
                        return manifest.parent, None
            for base in self.dirs:
                for candidate in (base / f"{key.name}-{key.version}", base / key.name):
                    if (candidate / "Cargo.toml").is_file():
                        return candidate, None
            raise NoticeError(f"git package {key.name} {key.version} ({package.source}) has no source checkout")
        for base in self.dirs:
            for candidate in (base / f"{key.name}-{key.version}", base / key.name):
                manifest = candidate / "Cargo.toml"
                if manifest.is_file() and _manifest_version(candidate, self) == key.version:
                    return candidate, None
        raise NoticeError(f"{key.name} {key.version}: no source directory in --sources or CARGO_HOME (run `cargo fetch --locked` or `cargo vendor` where cargo runs)")


def _manifest_version(crate_dir: Path, sources: Sources) -> str | None:
    package = tomllib.loads((crate_dir / "Cargo.toml").read_text(encoding="utf-8")).get("package", {})
    version = package.get("version")
    if isinstance(version, dict) and version.get("workspace") is True:
        ws = sources.workspace_for(crate_dir) or {}
        version = ws.get("package", {}).get("version")
    return version


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
        allowed = {"extra_license_files", "license_texts", "elections", "comment"}
        unknown = set(data) - allowed
        if unknown:
            raise NoticeError(f"{path}: unknown keys {sorted(unknown)}")
        return cls(path.parent, data.get("extra_license_files", {}), data.get("license_texts", {}), data.get("elections", {}))

    @staticmethod
    def lookup(table: dict, key: Key):
        return table.get(f"{key.name} {key.version}", table.get(key.name))


# Model -------------------------------------------------------------------------


@dataclasses.dataclass
class LicenseFile:
    name: str  # path inside the crate directory (or reviewed:<name>)
    data: bytes

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.data).hexdigest()


@dataclasses.dataclass
class Crate:
    key: Key
    first_party: bool
    declared: str
    concluded: str
    download: str
    checksum: str | None
    files: list[LicenseFile]
    closure: str  # "exact (cargo tree)" or "lock text"
    roots: list[str]


def spdx_expression(text: str | None) -> str | None:
    if not text:
        return None
    # Cargo's legacy "A/B" separator means A OR B.
    return " OR ".join(part.strip() for part in text.split("/")) if "/" in text else text.strip()


def slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9.-]+", "-", text).strip("-")


def resolve_closure(
    lock: dict[Key, LockPackage],
    roots: list[str],
    target: dict,
    sources: Sources,
) -> tuple[dict[Key, set[str]], dict[Key, Manifest], dict[Key, tuple[Path, Path | None]]]:
    manifests: dict[Key, Manifest] = {}
    locations: dict[Key, tuple[Path, Path | None]] = {}

    def manifest(key: Key) -> Manifest:
        if key not in manifests:
            location = sources.locate(lock[key])
            locations[key] = location
            manifests[key] = read_manifest(location[0] / "Cargo.toml", target, sources.workspace_for(location[0]))
        return manifests[key]

    reached: dict[Key, set[str]] = {}
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
    return reached, manifests, locations


def parse_cargo_tree(path: Path) -> set[Key]:
    keys: set[Key] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) < 2 or not parts[1].startswith("v"):
            continue
        if "(proc-macro)" in line:
            continue
        keys.add(Key(parts[0], parts[1][1:]))
    return keys


def collect(args: argparse.Namespace) -> list[Crate]:
    target = _target(args.target)
    lock = read_lock(args.lock)
    sources = Sources(args.sources, args.workspace)
    reviewed = Reviewed.load(args.reviewed)
    reached, manifests, locations = resolve_closure(lock, args.root, target, sources)
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
        rel = crate_dir.resolve().relative_to(ws_root.resolve()).as_posix() if ws_root else None
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
            prefix = args.source_tag_path_prefix.rstrip("/")
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
            text = Reviewed.lookup(reviewed.texts, key)
            if text is not None:
                files.append(LicenseFile(f"reviewed-{Path(text['file']).name}", (reviewed.base / text["file"]).read_bytes()))
            source = lock[key].source
            if source == CRATES_IO:
                download = f"https://crates.io/api/v1/crates/{key.name}/{key.version}/download"
            elif source and source.startswith("git+"):
                url, _, rev = source[4:].partition("#")
                download = f"git+{url.split('?')[0]}@{rev}"
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
        crates.append(Crate(key, first_party, declared, concluded, download, lock[key].checksum, files, closure_label, sorted(reached[key])))
    if errors:
        raise NoticeError("\n".join(errors))
    return crates


# Renderers --------------------------------------------------------------------


def file_path(crate: Crate, lf: LicenseFile) -> str:
    return f"{crate.key.name}-{crate.key.version}/{lf.name}"


def render_spdx(crates: list[Crate], args: argparse.Namespace) -> str:
    idp = args.spdx_id_prefix
    packages, files, relationships, extracted = [], [], [], {}
    for crate in crates:
        pid = f"{idp}rust-{slug(crate.key.name)}-{slug(crate.key.version)}"
        package = {
            "SPDXID": pid,
            "name": args.spdx_prefix + crate.key.name,
            "versionInfo": crate.key.version,
            "downloadLocation": crate.download,
            "filesAnalyzed": False,
            "licenseConcluded": crate.concluded,
            "licenseDeclared": crate.declared,
            "copyrightText": "NOASSERTION",
            "comment": f"closure: {crate.closure}; roots: {', '.join(crate.roots)}; {'first-party' if crate.first_party else 'third-party'}",
        }
        if crate.checksum:
            package["checksums"] = [{"algorithm": "SHA256", "checksumValue": crate.checksum}]
        packages.append(package)
        relationships.append({"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": pid})
        for lf in crate.files:
            fid = f"{idp}rust-file-{slug(file_path(crate, lf))}"
            files.append({
                "SPDXID": fid,
                "fileName": file_path(crate, lf),
                "checksums": [{"algorithm": "SHA256", "checksumValue": lf.sha256}],
                "licenseConcluded": "NOASSERTION",
                "copyrightText": "NOASSERTION",
            })
            relationships.append({"spdxElementId": pid, "relationshipType": "CONTAINS", "relatedSpdxElement": fid})
        for ref in re.findall(r"LicenseRef-[A-Za-z0-9.-]+", crate.declared + " " + crate.concluded):
            extracted.setdefault(ref, crate.files[0].data.decode("utf-8", errors="replace"))
    body = {
        "packages": packages,
        "files": files,
        "relationships": relationships,
        "hasExtractedLicensingInfos": [{"licenseId": k, "extractedText": v} for k, v in sorted(extracted.items())],
    }
    digest = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": args.title,
        "documentNamespace": f"https://cmux.com/spdx/rust-notices/{slug(args.title)}-{digest}",
        "creationInfo": {"creators": [f"Tool: {TOOL}"], "created": args.created},
        **body,
    }
    return json.dumps(document, indent=2, sort_keys=False, ensure_ascii=False) + "\n"


def fence(text: str) -> str:
    longest = max((len(m) for m in re.findall(r"`+", text)), default=0)
    return "`" * max(3, longest + 1)


def render_markdown(crates: list[Crate], args: argparse.Namespace) -> str:
    out = [f"<!-- notices-section: {args.section_id} -->", f"## {args.title}", ""]
    out.append(
        f"Generated by cmux-tui/build-support/notices/{TOOL} from `{args.lock_label or args.lock.name}` "
        f"(roots: {', '.join(args.root)}; target {args.target}; closure: "
        f"{crates[0].closure if crates else 'empty'}). Each crate lists its license files; "
        "identical license texts are printed once, under \"License texts\"."
    )
    out.append("")
    texts: dict[str, bytes] = {}
    for crate in crates:
        refs = []
        for lf in crate.files:
            texts.setdefault(lf.sha256, lf.data)
            refs.append(f"`{lf.name}` (text {lf.sha256[:12]})")
        license_line = crate.concluded if crate.concluded == crate.declared else f"{crate.concluded} (elected from {crate.declared})"
        out.append(f"- **{crate.key.name} {crate.key.version}**: {license_line}. Source: {crate.download}. Files: {', '.join(refs)}")
    out += ["", f"### License texts ({args.title})", ""]
    for sha, data in sorted(texts.items()):
        text = data.decode("utf-8", errors="replace")
        f = fence(text)
        out += [f"#### Text {sha[:12]}", "", f + "text", text.rstrip("\n"), f, ""]
    return "\n".join(out) + "\n"


def write_files(crates: list[Crate], root: Path) -> None:
    for crate in crates:
        for lf in crate.files:
            dest = root / file_path(crate, lf)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(lf.data)


def tree_digest(root: Path) -> dict[str, str]:
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob("*")) if p.is_file()}


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--lock", type=Path, required=True)
    p.add_argument("--lock-label", help="lock path to print in the markdown header (default: file name)")
    p.add_argument("--root", action="append", required=True, help="package that is linked into the binary (repeatable)")
    p.add_argument("--target", default="aarch64-apple-darwin")
    p.add_argument("--sources", type=Path, action="append", default=[], help="cargo vendor or registry src directory (repeatable)")
    p.add_argument("--workspace", type=Path, action="append", default=[], help="workspace root that holds path packages (repeatable)")
    p.add_argument("--first-party", action="append", default=[], help="glob (relative to its workspace) of first-party path packages")
    p.add_argument("--first-party-license", type=Path, help="license file for first-party crates (copied verbatim)")
    p.add_argument("--first-party-license-name", default="LICENSE")
    p.add_argument("--source-tag", help="permanent source tag for first-party downloadLocation, e.g. cmux-tui-src-b8feb806d6e")
    p.add_argument("--source-tag-path-prefix", default="cmux-tui", help="path of the workspace inside manaflow-ai/cmux")
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
    except NoticeError as error:
        print(f"rust_notices: error: {error}", file=sys.stderr)
        return 1
    text = render_spdx(crates, args) if args.format == "spdx-json" else render_markdown(crates, args)
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
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    if args.files_out:
        write_files(crates, args.files_out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
