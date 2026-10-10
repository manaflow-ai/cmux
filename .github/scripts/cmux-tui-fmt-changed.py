#!/usr/bin/env python3
"""Run `cargo fmt --check` on each cmux-tui package a change touches.

Usage: cmux-tui-fmt-changed.py [--repo ROOT] [--base SHA]

PR CI never runs cmux-tui.yml (dispatch only), so #18706 landed unformatted
Rust and broke base `cargo fmt --check`. This checks the tracked packages
under cmux-tui/ owning a changed .rs file or Cargo.toml between --base and
HEAD; with no usable base, or when a rustfmt config or the toolchain pin
changes, it checks every tracked package. Vendored crates (cmux-tui/vendor/)
keep their upstream formatting and are never checked. rustfmt reads metadata only
(`--no-deps`), so nothing builds and no dependency downloads. Every touched
package is checked even after one fails, and each red one is named.
"""

from __future__ import annotations

import argparse
from pathlib import Path, PurePosixPath
import subprocess
import sys


ROOT = "cmux-tui"
VENDOR = f"{ROOT}/vendor/"
EVERYTHING = frozenset({"rustfmt.toml", ".rustfmt.toml", "rust-toolchain.toml"})


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout


def packages(repo: Path) -> set[str]:
    """Tracked package directories (a Cargo.toml with a [package] table) under cmux-tui/."""
    found = set()
    for path in git(repo, "ls-files", "-z", "--", ROOT).split("\0"):
        if PurePosixPath(path).name != "Cargo.toml" or path.startswith(VENDOR) or not (repo / path).is_file():
            continue
        if any(line.strip() == "[package]" for line in (repo / path).read_text(encoding="utf-8").splitlines()):
            found.add(str(PurePosixPath(path).parent))
    return found


def changed(repo: Path, base: str) -> list[str] | None:
    """Paths under cmux-tui/ changed since `base`, or None when there is no usable base."""
    if not base or set(base) == {"0"}:
        return None
    try:
        git(repo, "cat-file", "-e", f"{base}^{{commit}}")
    except subprocess.CalledProcessError:
        print(f"cmux-tui-fmt-changed: base {base} is not in this checkout; checking every package")
        return None
    return [path for path in git(repo, "diff", "--name-only", "-z", base, "HEAD", "--", ROOT).split("\0") if path]


def manifest_dirs(repo: Path, base: str) -> set[str]:
    """Directories with a Cargo.toml at `base` or tracked now: a deleted package's files stop there."""
    listed = git(repo, "ls-tree", "-r", "-z", "--name-only", base, "--", ROOT).split("\0")
    listed += git(repo, "ls-files", "-z", "--", ROOT).split("\0")
    return {str(PurePosixPath(path).parent) for path in listed if PurePosixPath(path).name == "Cargo.toml"}


def touched(paths: list[str], known: set[str], boundaries: set[str]) -> set[str]:
    """The current packages owning changed Rust sources or manifests (the nearest Cargo.toml up)."""
    owners = set()
    for path in paths:
        pure = PurePosixPath(path)
        if path.startswith(VENDOR) or (pure.suffix != ".rs" and pure.name != "Cargo.toml"):
            continue
        owner = next((str(parent) for parent in pure.parents if str(parent) in boundaries), None)
        if owner in known:
            owners.add(owner)
    return owners


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path)
    parser.add_argument("--base", default="")
    args = parser.parse_args(argv)
    repo = (args.repo or Path(git(Path.cwd(), "rev-parse", "--show-toplevel").strip())).resolve()
    known = packages(repo)
    paths = changed(repo, args.base.strip())
    if paths is None or any(PurePosixPath(path).name in EVERYTHING for path in paths):
        selected = known
    else:
        selected = touched(paths, known, manifest_dirs(repo, args.base.strip()))
    if not selected:
        print("cmux-tui-fmt-changed: no cmux-tui package changed")
        return 0
    red = []
    for package in sorted(selected):
        manifest = repo / package / "Cargo.toml"
        print(f"cargo fmt --check --manifest-path {package}/Cargo.toml", flush=True)
        # From cmux-tui/ so rustup uses its rust-toolchain.toml pin.
        if subprocess.run(["cargo", "fmt", "--check", "--manifest-path", str(manifest)], cwd=repo / ROOT).returncode:
            red.append(package)
    for package in red:
        print(f"::error title=cmux-tui rustfmt::{package} is not rustfmt-clean; "
              f"run `cargo fmt --manifest-path {package}/Cargo.toml` from the repository root and commit the result")
    print(f"cmux-tui-fmt-changed: {len(selected) - len(red)}/{len(selected)} packages rustfmt-clean")
    return 1 if red else 0


if __name__ == "__main__":
    sys.exit(main())
