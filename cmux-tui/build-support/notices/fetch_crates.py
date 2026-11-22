#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fill a CARGO_HOME-shaped source cache for one or more Cargo.lock files,
without cargo (Python 3.11+ standard library and git).

  fetch_crates.py --lock A/Cargo.lock [--lock B/Cargo.lock ...] --cache DIR

crates.io packages: DIR/registry/src/index.crates.io-notices/<name>-<version>,
extracted from https://static.crates.io/crates/<name>/<name>-<version>.crate
after its SHA-256 equals the lock checksum. Git packages:
DIR/git/checkouts/<repo>-<url digest>/<rev[:7]>, a checkout of the exact
revision. Directories that already exist are kept. Run rust_notices.py with
CARGO_HOME=DIR so that it reads these sources and nothing else.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tomllib
import urllib.request

CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"
REGISTRY_DIR = "index.crates.io-notices"


def crate_dir(cache: Path, package: dict) -> Path:
    return cache / "registry" / "src" / REGISTRY_DIR / f"{package['name']}-{package['version']}"


def git_dir(cache: Path, source: str) -> tuple[Path, str, str]:
    url, _, rev = source[4:].partition("#")
    url = url.split("?")[0]
    repo = url.rstrip("/").removesuffix(".git").rsplit("/", 1)[-1]
    digest = hashlib.sha256(url.encode()).hexdigest()[:16]
    return cache / "git" / "checkouts" / f"{repo}-{digest}" / rev[:7], url, rev


def fetch_crate(cache: Path, package: dict) -> None:
    dest = crate_dir(cache, package)
    if dest.is_dir():
        return
    name, version = package["name"], package["version"]
    url = f"https://static.crates.io/crates/{name}/{name}-{version}.crate"
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != package.get("checksum"):
        raise SystemExit(f"fetch_crates: {name} {version}: downloaded sha256 {digest} differs from Cargo.lock {package.get('checksum')}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    partial = dest.with_name(dest.name + ".partial")
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        archive.extractall(partial, filter="data")
    (partial / f"{name}-{version}").rename(dest)
    partial.rmdir()


def fetch_git(cache: Path, source: str) -> None:
    dest, url, rev = git_dir(cache, source)
    if dest.is_dir():
        return
    partial = dest.with_name(dest.name + ".partial")
    partial.mkdir(parents=True, exist_ok=True)
    for command in (["init", "-q"], ["fetch", "-q", "--depth", "1", url, rev], ["checkout", "-q", "FETCH_HEAD"]):
        subprocess.run(["git", "-C", str(partial), *command], check=True)
    head = subprocess.run(["git", "-C", str(partial), "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    if head != rev:
        raise SystemExit(f"fetch_crates: {url}: checked out {head}, Cargo.lock wants {rev}")
    partial.rename(dest)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lock", type=Path, action="append", required=True)
    parser.add_argument("--cache", type=Path, required=True)
    args = parser.parse_args(argv)
    git_sources: set[str] = set()
    crates: dict[tuple[str, str], dict] = {}
    for lock in args.lock:
        for package in tomllib.loads(lock.read_text(encoding="utf-8")).get("package", []):
            source = package.get("source")
            if source == CRATES_IO:
                crates[(package["name"], package["version"])] = package
            elif source and source.startswith("git+"):
                git_sources.add(source)
    count = len(crates)
    with ThreadPoolExecutor(max_workers=8) as pool:
        for future in [pool.submit(fetch_crate, args.cache, crates[key]) for key in sorted(crates)]:
            future.result()
    for source in sorted(git_sources):
        fetch_git(args.cache, source)
    print(f"fetch_crates: {count} crates.io packages and {len(git_sources)} git revisions in {args.cache}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
