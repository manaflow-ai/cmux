#!/usr/bin/env python3
"""Run `cargo clippy --all-targets -D warnings` on each cmux-tui workspace package a change touches.

Usage: cmux-tui-clippy-changed.py [--repo ROOT] [--base SHA]

PR CI never runs cmux-tui.yml (dispatch only), whose workspace clippy is the
only `--all-targets` lint of cmux-tui, and the fast tier's cargo entries only
run tests. So #23163 and #23372 landed clippy reds in cmux-tui/crates/cmux-tui/tests/
and broke base clippy for everyone. This lints the cmux-tui workspace members
owning a changed .rs file or Cargo.toml between --base and HEAD (tests, benches
and examples included), in one `cargo clippy --keep-going` so each red package
is reported. A change to the workspace manifest, the lockfile, a clippy config
or the toolchain pin, or no usable base, lints the whole workspace. Packages
with a workspace of their own (cmux-rd-ffi, cmux-rd-host, ...) and vendored
crates are not members and stay with cmux-tui.yml's dispatch run. Which files
map to which package is cmux-tui-fmt-changed.py's rule, shared from there.
Packages that only depend on a changed one are not linted here; the
workspace clippy in cmux-tui.yml is where a break reaching them shows.
"""

from __future__ import annotations

import argparse
from fnmatch import fnmatch
import importlib.util
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tomllib


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


def members(repo: Path, known: set[str]) -> dict[str, str]:
    """The workspace's member package directories (repository-relative), each with its package name."""
    manifest = tomllib.loads((repo / ROOT / "Cargo.toml").read_text(encoding="utf-8"))
    patterns = [f"{ROOT}/{member}".rstrip("/") for member in manifest.get("workspace", {}).get("members", [])]
    excluded = [f"{ROOT}/{path}".rstrip("/") for path in manifest.get("workspace", {}).get("exclude", [])]
    dirs = {path for path in known if any(fnmatch(path, pattern) for pattern in patterns)}
    if "package" in manifest:
        dirs.add(ROOT)
    dirs = {path for path in dirs if not any(path == ex or path.startswith(f"{ex}/") for ex in excluded)}
    names = {}
    for path in dirs:
        package = tomllib.loads((repo / path / "Cargo.toml").read_text(encoding="utf-8")).get("package", {})
        if "name" in package:
            names[path] = package["name"]
    return names


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path)
    parser.add_argument("--base", default="")
    args = parser.parse_args(argv)
    repo = (args.repo or Path(fmt_changed.git(Path.cwd(), "rev-parse", "--show-toplevel").strip())).resolve()
    known = fmt_changed.packages(repo)
    workspace = members(repo, known)
    base = args.base.strip()
    paths = fmt_changed.changed(repo, base)
    if paths is None or any(path in WHOLE_WORKSPACE for path in paths):
        command = ["cargo", "clippy", "--locked", "--keep-going", "--workspace", "--all-targets", "--", "-D", "warnings"]
        scope = "the whole cmux-tui workspace"
    else:
        touched = fmt_changed.touched(paths, known, fmt_changed.manifest_dirs(repo, base))
        for path in sorted(touched - workspace.keys()):
            print(f"cmux-tui-clippy-changed: {path} is not a cmux-tui workspace member (cmux-tui.yml lints it)")
        selected = sorted(workspace[path] for path in touched if path in workspace)
        if not selected:
            print("cmux-tui-clippy-changed: no cmux-tui workspace package changed")
            return 0
        packages = [arg for name in selected for arg in ("-p", name)]
        command = ["cargo", "clippy", "--locked", "--keep-going", *packages, "--all-targets", "--", "-D", "warnings"]
        scope = ", ".join(selected)
    print(f"cmux-tui-clippy-changed: linting {scope}", flush=True)
    print(" ".join(command), flush=True)
    # From cmux-tui/ so rustup uses its rust-toolchain.toml pin and cargo its workspace.
    rc = subprocess.run(command, cwd=repo / ROOT).returncode
    if rc:
        print(f"::error title=cmux-tui clippy::clippy -D warnings failed for {scope}; "
              f"run `{' '.join(command)}` in cmux-tui and fix each lint (an allow needs a comment saying why)")
    return 1 if rc else 0


if __name__ == "__main__":
    sys.exit(main())
