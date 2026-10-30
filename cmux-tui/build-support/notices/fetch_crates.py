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
import http.client
import io
import shutil
from pathlib import Path
import subprocess
import sys
import tarfile
import time
import tomllib
import urllib.error
import urllib.request

CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"
REGISTRY_DIR = "index.crates.io-notices"
ATTEMPTS = 4  # one network hiccup must not fail a nightly; waits 2, 4, 8 s


def transient(error: BaseException) -> bool:
    if isinstance(error, urllib.error.HTTPError):
        return error.code == 429 or error.code >= 500
    if isinstance(error, subprocess.CalledProcessError):
        return True  # git fetch prints its own error to stderr
    # URLError, TimeoutError, ConnectionError and ssl errors are all OSError; IncompleteRead is an HTTPException.
    return isinstance(error, (OSError, http.client.HTTPException))


def retry(what: str, call):
    for attempt in range(1, ATTEMPTS + 1):
        try:
            return call()
        except Exception as error:
            if attempt == ATTEMPTS or not transient(error):
                raise
            print(f"fetch_crates: {what}: {error}; attempt {attempt + 1}/{ATTEMPTS} in {2 ** attempt} s", file=sys.stderr)
            time.sleep(2 ** attempt)  # bounded network backoff, not synchronization


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

    def download() -> bytes:
        with urllib.request.urlopen(url, timeout=120) as response:
            return response.read()

    data = retry(f"{name} {version}", download)
    digest = hashlib.sha256(data).hexdigest()
    if digest != package.get("checksum"):
        raise SystemExit(f"fetch_crates: {name} {version}: downloaded sha256 {digest} differs from Cargo.lock {package.get('checksum')}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    partial = dest.with_name(dest.name + ".partial")
    # A cache kept between runs (nightly-next's trusted worker) can hold the
    # leftover of an interrupted extract; start it over.
    shutil.rmtree(partial, ignore_errors=True)
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        archive.extractall(partial, filter="data")
    (partial / f"{name}-{version}").rename(dest)
    partial.rmdir()


def fetch_git(cache: Path, source: str) -> None:
    dest, url, rev = git_dir(cache, source)
    if dest.is_dir():
        # The directory is named by rev[:7]; a kept cache may hold another
        # revision with that prefix. Use it only when it is this one.
        kept = subprocess.run(["git", "-C", str(dest), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        if kept == rev:
            return
        shutil.rmtree(dest)
    partial = dest.with_name(dest.name + ".partial")
    # An interrupted fetch or checkout (a stale index.lock) must not fail every later run.
    shutil.rmtree(partial, ignore_errors=True)
    partial.mkdir(parents=True)
    git = ["git", "-C", str(partial)]
    subprocess.run([*git, "init", "-q"], check=True)
    retry(f"git fetch {url} {rev}", lambda: subprocess.run([*git, "fetch", "-q", "--depth", "1", url, rev], check=True))
    subprocess.run([*git, "checkout", "-q", "FETCH_HEAD"], check=True)
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
