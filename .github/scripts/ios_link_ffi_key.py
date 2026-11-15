#!/usr/bin/env python3
"""The cache key for CmuxMobileLinkFFI.xcframework: what its build reads, by git object id.

cmux-next-ios/rust/scripts/build-xcframework.sh compiles the cmux-mobile-link-ffi
workspace and every crate it reaches through a `path =` dependency (most of them
under cmux-tui/crates and cmux-tui/vendor). The key hashes, at one commit:

- the git tree of the workspace and of every crate it reaches by path, followed
  transitively;
- every Cargo.toml, rust-toolchain(.toml) and .cargo/config(.toml) in a directory
  above one of those, up to the repository root (a crate's `workspace = true`
  fields, its toolchain and its cargo flags come from there);
- any extra inputs named with --extra (the Xcode build, the deployment target).

Two commits with the same key build the same framework, so a job may restore it
instead of building. Only git object ids are read, so it is the same on Linux and
on a Mac and costs no build.

  ios_link_ffi_key.py --repo . [--rev HEAD] [--workspace cmux-next-ios/rust] [--extra TEXT]...

prints `key=<hex>` and, with --explain, every input on stderr.
"""

from __future__ import annotations

import argparse
import hashlib
import posixpath
import re
import subprocess
import sys

# `path = "..."` in any form Cargo reads: an inline table, a [dependencies.x]
# table or a [patch] entry. Only relative paths inside the repository count.
PATH_DEP = re.compile(r"""(?m)^[^#\n]*?\bpath\s*=\s*["']([^"']+)["']""")
ANCESTOR_FILES = ("Cargo.toml", "rust-toolchain", "rust-toolchain.toml", ".cargo/config", ".cargo/config.toml")


def git(repo: str, *args: str) -> str:
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout


def object_id(repo: str, rev: str, path: str) -> str | None:
    out = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", f"{rev}:{path}"],
                         capture_output=True, text=True)
    return out.stdout.strip() or None


def manifests_under(repo: str, rev: str, directory: str) -> list[str]:
    names = git(repo, "ls-tree", "-r", "--name-only", rev, "--", directory).splitlines()
    return [n for n in names if posixpath.basename(n) == "Cargo.toml"]


def crate_dirs(repo: str, rev: str, workspace: str) -> list[str]:
    """The workspace and every directory it reaches by `path =`, transitively."""
    seen: set[str] = set()
    queue = [workspace]
    while queue:
        directory = posixpath.normpath(queue.pop())
        if directory in seen:
            continue
        if directory.startswith("..") or directory.startswith("/"):
            raise SystemExit(f"error: {directory} is outside the repository")
        if object_id(repo, rev, directory) is None:
            raise SystemExit(f"error: {directory} is not in {rev}")
        seen.add(directory)
        for manifest in manifests_under(repo, rev, directory):
            text = git(repo, "show", f"{rev}:{manifest}")
            base = posixpath.dirname(manifest)
            for target in PATH_DEP.findall(text):
                dep = posixpath.normpath(posixpath.join(base, target))
                # A [[bin]] or [lib] `path` names a source file inside the
                # crate, already in its tree.
                if dep.endswith(".rs"):
                    continue
                if not any(dep == d or dep.startswith(d + "/") for d in seen):
                    queue.append(dep)
    # Drop directories inside another one already hashed whole.
    return sorted(d for d in seen if not any(d != o and d.startswith(o + "/") for o in seen))


def ancestor_files(repo: str, rev: str, dirs: list[str]) -> list[str]:
    found: set[str] = set()
    for directory in dirs:
        parent = posixpath.dirname(directory)
        while True:
            for name in ANCESTOR_FILES:
                path = posixpath.join(parent, name) if parent else name
                if object_id(repo, rev, path) is not None:
                    found.add(path)
            if not parent:
                break
            parent = posixpath.dirname(parent)
    return sorted(found)


def key(repo: str, rev: str, workspace: str, extra: list[str]) -> tuple[str, list[str]]:
    dirs = crate_dirs(repo, rev, workspace)
    lines = [f"tree {d} {object_id(repo, rev, d)}" for d in dirs]
    lines += [f"file {f} {object_id(repo, rev, f)}" for f in ancestor_files(repo, rev, dirs)]
    lines += [f"extra {e}" for e in extra]
    return hashlib.sha256("\n".join(lines).encode()).hexdigest(), lines


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--rev", default="HEAD")
    parser.add_argument("--workspace", default="cmux-next-ios/rust")
    parser.add_argument("--extra", action="append", default=[])
    parser.add_argument("--explain", action="store_true")
    args = parser.parse_args(argv)
    digest, lines = key(args.repo, args.rev, args.workspace, args.extra)
    if args.explain:
        print("\n".join(lines), file=sys.stderr)
    print(f"key={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
