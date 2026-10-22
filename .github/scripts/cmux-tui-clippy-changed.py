#!/usr/bin/env python3
"""Run `cargo clippy --all-targets -D warnings` on each cmux-tui workspace package a change touches.

Usage: cmux-tui-clippy-changed.py [--repo ROOT] [--base SHA]

PR CI never runs cmux-tui.yml (dispatch only), whose workspace clippy is the
only `--all-targets` lint of cmux-tui, and the fast tier's cargo entries only
run tests. So #23163 and #23372 landed clippy reds in cmux-tui/crates/cmux-tui/tests/
and broke base clippy for everyone. This lints the cmux-tui workspace members
owning a changed .rs file or Cargo.toml between --base and HEAD (tests, benches
and examples included), plus every member that depends on one of them, in one
`cargo clippy --keep-going` so each red package is reported. Members and their
path dependencies come from `cargo metadata --no-deps`. A change to the workspace
manifest, the lockfile, a clippy config or the toolchain pin, or no usable base,
lints the whole workspace. Packages with a workspace of their own (cmux-rd-ffi,
cmux-rd-host, ...) and vendored crates are not members and stay with
cmux-tui.yml's dispatch run. Which files map to which package is
cmux-tui-fmt-changed.py's rule, shared from there.
"""

from __future__ import annotations

import argparse
from collections import deque
import importlib.util
import json
from pathlib import Path
import subprocess
import sys


def _load_fmt_changed():
    spec = importlib.util.spec_from_file_location("cmux_tui_fmt_changed", Path(__file__).with_name("cmux-tui-fmt-changed.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fmt_changed = _load_fmt_changed()
ROOT = fmt_changed.ROOT
WHOLE_WORKSPACE = frozenset({
    f"{ROOT}/Cargo.toml", f"{ROOT}/Cargo.lock", f"{ROOT}/clippy.toml", f"{ROOT}/.clippy.toml",
    f"{ROOT}/rust-toolchain.toml", f"{ROOT}/rust-toolchain", f"{ROOT}/.cargo/config.toml",
})


def workspace_of(repo: Path) -> tuple[dict[str, str], dict[str, set[str]]]:
    """The members' directories (repository-relative) with their package names, and each
    member's dependents: the members naming it as a path dependency of any kind."""
    meta = json.loads(subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--no-deps"],
        cwd=repo / ROOT, check=True, stdout=subprocess.PIPE, text=True,
    ).stdout)
    top = repo.resolve()
    ids = set(meta["workspace_members"])
    packages = [package for package in meta["packages"] if package["id"] in ids]
    names = {Path(package["manifest_path"]).resolve().parent.relative_to(top).as_posix(): package["name"]
             for package in packages}
    by_dir = {top / path: name for path, name in names.items()}
    dependents: dict[str, set[str]] = {name: set() for name in names.values()}
    for package in packages:
        for dependency in package["dependencies"]:
            target = by_dir.get(Path(dependency["path"]).resolve()) if dependency.get("path") else None
            if target and target != package["name"]:
                dependents[target].add(package["name"])
    return names, dependents


def with_dependents(changed: set[str], dependents: dict[str, set[str]]) -> set[str]:
    """`changed` and every member that depends on one of them, directly or through others."""
    seen, queue = set(changed), deque(changed)
    while queue:
        for user in dependents.get(queue.popleft(), ()):
            if user not in seen:
                seen.add(user)
                queue.append(user)
    return seen


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path)
    parser.add_argument("--base", default="")
    args = parser.parse_args(argv)
    repo = (args.repo or Path(fmt_changed.git(Path.cwd(), "rev-parse", "--show-toplevel").strip())).resolve()
    known = fmt_changed.packages(repo)
    try:
        workspace, dependents = workspace_of(repo)
    except subprocess.CalledProcessError:
        print("::error title=cmux-tui clippy::`cargo metadata --no-deps` failed in cmux-tui (its error is above); "
              "fix the manifest it names")
        return 1
    base = args.base.strip()
    paths = fmt_changed.changed(repo, base)
    if paths is None or any(path in WHOLE_WORKSPACE for path in paths):
        command = ["cargo", "clippy", "--locked", "--keep-going", "--workspace", "--all-targets", "--", "-D", "warnings"]
        scope = "the whole cmux-tui workspace"
    else:
        touched = fmt_changed.touched(paths, known, fmt_changed.manifest_dirs(repo, base))
        for path in sorted(touched - workspace.keys()):
            print(f"cmux-tui-clippy-changed: {path} is not a cmux-tui workspace member (cmux-tui.yml lints it)")
        changed = {workspace[path] for path in touched if path in workspace}
        if not changed:
            print("cmux-tui-clippy-changed: no cmux-tui workspace package changed")
            return 0
        selected = sorted(with_dependents(changed, dependents))
        if users := [name for name in selected if name not in changed]:
            print(f"cmux-tui-clippy-changed: {', '.join(users)} depend on {', '.join(sorted(changed))}")
        packages = [arg for name in selected for arg in ("-p", name)]
        command = ["cargo", "clippy", "--locked", "--keep-going", *packages, "--all-targets", "--", "-D", "warnings"]
        scope = ", ".join(selected)
    print(f"cmux-tui-clippy-changed: linting {scope}", flush=True)
    print(" ".join(command), flush=True)
    # From cmux-tui/ so rustup uses its rust-toolchain.toml pin and cargo its workspace.
    rc = subprocess.run(command, cwd=repo / ROOT).returncode
    if rc:
        print(f"::error title=cmux-tui clippy::clippy -D warnings failed for {scope}; "
              f"run `{' '.join(command)}` in cmux-tui and fix each lint (an allow needs a comment saying why); "
              f"a red in a package you did not touch may already be red on the base branch")
    return 1 if rc else 0


if __name__ == "__main__":
    sys.exit(main())
