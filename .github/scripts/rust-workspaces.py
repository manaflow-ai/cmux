#!/usr/bin/env python3
"""Pull-request clippy and tests for every Cargo workspace outside the cmux-tui one.

Usage:
  rust-workspaces.py check [--repo ROOT]
  rust-workspaces.py plan [--repo ROOT] [--base SHA]
  rust-workspaces.py run ROOT [--repo ROOT]

Only cmux-tui's own workspace had PR clippy (cmux-tui-spec.yml), and the
workspaces beside it (optchat-chief, the cmux-tui FFI and host crates with a
[workspace] of their own, cmux-next-ios/rust, the cloud server, ...) had no PR
clippy or tests at all, or only a dispatch or fleet run. .github/rust-workspaces.toml
lists every workspace and says how it is checked.

`check` fails when that list and the tree disagree: a workspace with no entry,
an entry for something that is not a workspace, or a `covered_by` workflow that
does not name its root. `plan` prints, as JSON for a job matrix, the `run = true`
workspaces a change between --base and HEAD reaches: a file under the workspace,
or under a package it uses by path (any dependency kind of its own members; normal
and build dependencies further down), the manifest such a package inherits from, a
file those packages' sources read from elsewhere in the tree (an `include_str!`,
`include_bytes!` or `CARGO_MANIFEST_DIR` join of a literal path, or any "../..."
literal naming a tracked path), or a path in the entry's `inputs`. With no usable base, or when the list or
this check changes, it plans every one. `run` lints and tests one workspace:
`cargo clippy --workspace --all-targets -- -D warnings`, then `cargo test --workspace`,
with --locked when it tracks a Cargo.lock; both run, and either failing fails it.
"""

from __future__ import annotations

import argparse
from fnmatch import fnmatch
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
import tomllib


LIST = ".github/rust-workspaces.toml"
# A change to these plans every workspace.
EVERYTHING = frozenset({
    LIST,
    ".github/scripts/rust-workspaces.py",
    ".github/scripts/test_rust_workspaces.py",
    ".github/workflows/rust-workspaces.yml",
    ".github/actions/setup-cmux-tui-rust/action.yml",
    "cmux-tui/rust-toolchain.toml",
})
DEPENDENCY_TABLES = ("dependencies", "dev-dependencies", "build-dependencies")
# A literal path a source file reads: include_str!("p"), include_bytes!(concat!("p", ...)),
# relative to the file; or env!("CARGO_MANIFEST_DIR") joined with "p", relative to the package.
INCLUDE = re.compile(r'include_(?:str|bytes)!\(\s*(concat!\(\s*)?"([^"]+)"')
# Any other "../..." string literal: a helper's join or a build script's const. It counts
# when it names a tracked path from the source's directory or one above it.
PARENT_LITERAL = re.compile(r'"((?:\.\./)+[^"\s{}*]+)"')
MANIFEST_DIR = re.compile(
    r'(?:env!\(\s*"CARGO_MANIFEST_DIR"\s*\)\s*\)?\s*\.join\(\s*|concat!\(\s*env!\(\s*"CARGO_MANIFEST_DIR"\s*\)\s*,\s*)"([^"]+)"')


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout


class Tree:
    """The tracked Cargo manifests of a checkout."""

    def __init__(self, repo: Path):
        self.repo = repo
        tracked = [path for path in git(repo, "ls-files", "-z").split("\0") if path]
        self.sources = [path for path in tracked if path.endswith(".rs")]
        self.tracked = set(tracked) | {str(parent) for path in tracked for parent in PurePosixPath(path).parents}
        self.manifests: dict[str, dict] = {}
        for path in git(repo, "ls-files", "-z", "--", "*Cargo.toml", "Cargo.toml").split("\0"):
            if PurePosixPath(path).name == "Cargo.toml" and (repo / path).is_file():
                self.manifests[str(PurePosixPath(path).parent)] = tomllib.loads((repo / path).read_text(encoding="utf-8"))

    def workspace_above(self, directory: str) -> str | None:
        """The nearest directory above `directory` whose manifest has a [workspace] table."""
        for parent in PurePosixPath(directory).parents:
            key = str(parent)
            if "workspace" in self.manifests.get(key, {}):
                return key
        return None

    def excluded(self, root: str, directory: str) -> bool:
        relative = str(PurePosixPath(directory).relative_to(root))
        return any(relative == path.rstrip("/") or relative.startswith(path.rstrip("/") + "/")
                   for path in self.manifests[root]["workspace"].get("exclude", []))

    def roots(self) -> set[str]:
        """Every workspace: a [workspace] manifest, or a package outside every workspace."""
        found = set()
        for directory, manifest in self.manifests.items():
            if "workspace" in manifest:
                found.add(directory)
            elif "package" in manifest:
                above = self.workspace_above(directory)
                if above is None or self.excluded(above, directory):
                    found.add(directory)
        return found

    def members(self, root: str) -> set[str]:
        """The package directories of the workspace at `root`."""
        manifest = self.manifests[root]
        table = manifest.get("workspace")
        found = {root} if "package" in manifest else set()
        if table is None:
            return found
        patterns = [str(PurePosixPath(root) / member) for member in table.get("members", [])]
        for directory, other in self.manifests.items():
            if "package" in other and any(fnmatch(directory, pattern) for pattern in patterns) \
                    and not self.excluded(root, directory):
                found.add(directory)
        return found

    def path_dependencies(self, directory: str, kinds: tuple[str, ...]) -> set[str]:
        """Directories of the path dependencies the package at `directory` names in `kinds`."""
        manifest = self.manifests.get(directory, {})
        tables = [manifest.get(kind, {}) for kind in kinds]
        for target in manifest.get("target", {}).values():
            tables += [target.get(kind, {}) for kind in kinds]
        found = set()
        for table in tables:
            for name, spec in table.items():
                if not isinstance(spec, dict):
                    continue
                base = directory
                if spec.get("workspace") is True:
                    # Inherited from the package's workspace: its own manifest when it is the root.
                    base = directory if "workspace" in manifest else (self.workspace_above(directory) or directory)
                    spec = self.manifests.get(base, {}).get("workspace", {}).get("dependencies", {}).get(name, {})
                    if not isinstance(spec, dict):
                        continue
                if "path" in spec:
                    found.add(os.path.normpath(str(PurePosixPath(base) / spec["path"])))
        return found

    def reach(self, root: str) -> set[str]:
        """The workspace's root and members, and every package directory they use by path."""
        members = self.members(root)
        seen = members | {root}
        manifest = self.manifests[root]
        for spec in manifest.get("patch", {}).values():
            for patched in spec.values():
                if isinstance(patched, dict) and "path" in patched:
                    seen.add(os.path.normpath(str(PurePosixPath(root) / patched["path"])))
        queue = [(member, DEPENDENCY_TABLES) for member in members]
        while queue:
            directory, kinds = queue.pop()
            for dependency in self.path_dependencies(directory, kinds):
                if dependency not in seen:
                    seen.add(dependency)
                    queue.append((dependency, ("dependencies", "build-dependencies")))
        return seen

    def read_paths(self, directories: set[str]) -> set[str]:
        """Repository paths outside `directories` that their Rust sources read by literal path."""
        found = set()
        for directory in directories:
            for source in self.sources:
                if not under(source, directory) or not (self.repo / source).is_file():
                    continue
                text = (self.repo / source).read_text(encoding="utf-8", errors="replace")
                # A concat! prefix may stop inside a file name: watch its directory.
                read = [(PurePosixPath(source).parent, literal if not prefix or literal.endswith("/")
                         else str(PurePosixPath(literal).parent)) for prefix, literal in INCLUDE.findall(text)]
                read += [(PurePosixPath(directory), literal) for literal in MANIFEST_DIR.findall(text)]
                paths = {os.path.normpath(str(base / literal.lstrip("/"))) for base, literal in read}
                for literal in PARENT_LITERAL.findall(text):
                    for base in (PurePosixPath(source).parent, *PurePosixPath(source).parent.parents):
                        path = os.path.normpath(str(base / literal))
                        if path in self.tracked:
                            paths.add(path)
                for path in paths:
                    if not path.startswith("..") and not any(under(path, d) for d in directories):
                        found.add(path)
        return found

    def uses_package(self, directories: set[str], name: str) -> bool:
        return any(self.manifests.get(d, {}).get("package", {}).get("name") == name for d in directories)


def load_list(repo: Path) -> list[dict]:
    return tomllib.loads((repo / LIST).read_text(encoding="utf-8")).get("workspace", [])


def check(repo: Path) -> list[str]:
    """What is wrong with the list, one line each."""
    tree = Tree(repo)
    entries = load_list(repo)
    problems = []
    listed = [entry.get("root", "") for entry in entries]
    for root in sorted({r for r in listed if listed.count(r) > 1}):
        problems.append(f"{root} is listed more than once")
    actual = tree.roots()
    for root in sorted(actual - set(listed)):
        problems.append(f"{root} is a Cargo workspace with no entry in {LIST}: add one with run = true, "
                        "covered_by = \"<workflow>\" or skip = \"<why>\"")
    for entry in entries:
        root = entry.get("root", "")
        if root not in actual:
            problems.append(f"{root!r} in {LIST} is not a Cargo workspace root")
            continue
        kinds = [key for key in ("run", "covered_by", "skip") if key in entry]
        if len(kinds) != 1 or entry.get("run") is False:
            problems.append(f"{root} needs exactly one of run = true, covered_by or skip")
        elif kinds == ["covered_by"]:
            workflow = repo / entry["covered_by"]
            if not workflow.is_file() or root not in workflow.read_text(encoding="utf-8"):
                problems.append(f"{root}: {entry['covered_by']} does not exist or does not name {root}")
    return problems


def changed(repo: Path, base: str) -> list[str] | None:
    """Paths changed since `base`, or None when there is no usable base."""
    if not base or set(base) == {"0"}:
        return None
    try:
        git(repo, "cat-file", "-e", f"{base}^{{commit}}")
    except subprocess.CalledProcessError:
        print(f"rust-workspaces: base {base} is not in this checkout; planning every workspace", file=sys.stderr)
        return None
    return [path for path in git(repo, "diff", "--name-only", "-z", base, "HEAD").split("\0") if path]


def under(path: str, directory: str) -> bool:
    """`path` is `directory` or inside it."""
    return directory == "." or path == directory or path.startswith(directory + "/")


def plan(repo: Path, base: str) -> list[dict]:
    tree = Tree(repo)
    paths = changed(repo, base)
    if paths is not None and any(path in EVERYTHING for path in paths):
        paths = None
    jobs = []
    for entry in load_list(repo):
        if entry.get("run") is not True:
            continue
        root = entry["root"]
        reach = tree.reach(root)
        if paths is not None:
            # A dependency outside the workspace may inherit from its own workspace's manifest.
            watched = reach | {f"{above}/Cargo.toml" for above in map(tree.workspace_above, reach) if above}
            watched |= tree.read_paths(reach) | set(entry.get("inputs", []))
            if not any(under(path, directory) for path in paths for directory in watched):
                continue
        jobs.append({
            "root": root,
            "ghostty": tree.uses_package(reach, "ghostty-vt-sys"),
            "apt": " ".join(entry.get("apt", [])),
        })
    return jobs


def run(repo: Path, root: str) -> int:
    entry = next((entry for entry in load_list(repo) if entry.get("root") == root and entry.get("run") is True), None)
    if entry is None:
        print(f"::error title=rust-workspaces::{root} has no run = true entry in {LIST}")
        return 2
    locked = ["--locked"] if git(repo, "ls-files", "--", f"{root}/Cargo.lock").strip() else []
    args = list(entry.get("args", []))
    commands = [
        ("clippy", ["cargo", "clippy", *locked, "--workspace", "--all-targets", *args, "--", "-D", "warnings"]),
        ("test", ["cargo", "test", *locked, "--workspace", *args]),
    ]
    red = []
    # Tests that bind Unix sockets under TMPDIR need a path shorter than SUN_LEN.
    with tempfile.TemporaryDirectory(prefix="rw.", dir="/tmp") as short_tmp:
        env = {**os.environ, "TMPDIR": short_tmp}
        for name, command in commands:
            print(f"::group::{root}: {' '.join(command)}", flush=True)
            # From the workspace so rustup uses the nearest rust-toolchain.toml.
            rc = subprocess.run(command, cwd=repo / root, env=env).returncode
            print("::endgroup::", flush=True)
            if rc:
                red.append(name)
                print(f"::error title={root} {name}::`{' '.join(command)}` failed in {root}")
    print(f"rust-workspaces: {root}: " + (f"red ({', '.join(red)})" if red else "clippy and tests green"))
    return 1 if red else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=("check", "plan", "run"))
    parser.add_argument("root", nargs="?")
    parser.add_argument("--repo", type=Path)
    parser.add_argument("--base", default="")
    args = parser.parse_args(argv)
    repo = (args.repo or Path(git(Path.cwd(), "rev-parse", "--show-toplevel").strip())).resolve()
    if args.command == "check":
        problems = check(repo)
        for problem in problems:
            print(f"::error title=rust-workspaces list::{problem}")
        if not problems:
            print(f"rust-workspaces: {LIST} lists every Cargo workspace")
        return 1 if problems else 0
    if args.command == "plan":
        print(json.dumps(plan(repo, args.base.strip())))
        return 0
    if not args.root:
        parser.error("run needs a workspace root")
    return run(repo, args.root)


if __name__ == "__main__":
    sys.exit(main())
