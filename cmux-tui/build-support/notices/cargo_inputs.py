#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Cargo inputs of rust_notices.py: Cargo.lock, cfg() evaluation, manifests and
crate source directories (cargo vendor, CARGO_HOME registry and git checkouts)."""

from __future__ import annotations

import dataclasses
import json
import os
from pathlib import Path
import re
import tomllib

from notice_model import Key, LockPackage, NoticeError


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


TARGET_CFG = Path(__file__).resolve().parent / "target_cfg.json"
CFG_KEYS = ("target_arch", "target_os", "target_vendor", "target_env", "target_abi",
            "target_family", "target_pointer_width", "target_endian")


def target_info(triple: str) -> dict[str, object]:
    """The cfg values rustc sets for `triple` (target_cfg.json, generated from
    `rustc --print cfg --target <triple>`; never derived from the name)."""
    table = json.loads(TARGET_CFG.read_text(encoding="utf-8"))["targets"]
    cfg = table.get(triple)
    if cfg is None:
        raise NoticeError(
            f"unsupported --target {triple}: add it to {TARGET_CFG.name} from "
            "`rustc --print cfg --target` on a Testbox"
        )
    info: dict[str, object] = {key: cfg.get(key, "") for key in CFG_KEYS}
    info["flags"] = set(cfg.get("flags", []))
    info["triple"] = triple
    return info


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
    lib = data.get("lib", {})
    proc_macro = bool(lib.get("proc-macro", lib.get("proc_macro", False)))
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
        checkout = self.git_checkout_root(crate_dir)
        if checkout is not None:
            for parent in [crate_dir, *crate_dir.parents]:
                manifest = parent / "Cargo.toml"
                if manifest.is_file():
                    table = tomllib.loads(manifest.read_text(encoding="utf-8")).get("workspace")
                    if table is not None:
                        return table
                if parent == checkout:
                    break
        return None

    def git_checkout_root(self, crate_dir: Path) -> Path | None:
        """The checkout directory (CARGO_HOME/git/checkouts/<repo>/<rev>) that holds a git crate."""
        resolved = crate_dir.resolve()
        for base in self.git_dirs:
            if resolved.is_relative_to(base.resolve()):
                return base.resolve()
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
                    _check_vendor_checksum(candidate, package)
                    return candidate, None
        raise NoticeError(f"{key.name} {key.version}: no source directory in --sources or CARGO_HOME (run `cargo fetch --locked` or `cargo vendor` where cargo runs)")


def _check_vendor_checksum(crate_dir: Path, package: LockPackage) -> None:
    """A `cargo vendor` directory records the .crate digest; it must be the lock's."""
    record = crate_dir / ".cargo-checksum.json"
    if not record.is_file() or package.checksum is None:
        return
    vendored = json.loads(record.read_text(encoding="utf-8")).get("package")
    if vendored != package.checksum:
        raise NoticeError(f"{package.key.name} {package.key.version}: vendored checksum {vendored} differs from Cargo.lock {package.checksum}")


def _manifest_version(crate_dir: Path, sources: Sources) -> str | None:
    package = tomllib.loads((crate_dir / "Cargo.toml").read_text(encoding="utf-8")).get("package", {})
    version = package.get("version")
    if isinstance(version, dict) and version.get("workspace") is True:
        ws = sources.workspace_for(crate_dir) or {}
        version = ws.get("package", {}).get("version")
    return version


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


