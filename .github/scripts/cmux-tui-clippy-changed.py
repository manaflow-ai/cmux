#!/usr/bin/env python3
"""Run `cargo clippy --all-targets -D warnings` on each cmux-tui workspace package a change touches.

Usage: cmux-tui-clippy-changed.py [--repo ROOT] [--base SHA] [--panic-ratchet JSONL [--compare-base]]

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

--panic-ratchet JSONL runs the panic ratchet (scripts/cmux-next/rust_panic_ratchet.py,
plans/cmux-next/rust-panic-free.md) on the same packages instead: their production
targets (--lib --bins) are linted with the ratchet's flags into JSONL, and the ratchet
judges the counts against the baseline at HEAD. Only cmux-tui.yml ran it before, so
#27935 landed two acpmux indexing_slicing hits that turned base red. A crate the run
does not check keeps its baseline (the ratchet names it in a warning).

--compare-base (with --panic-ratchet and a base) lints the same packages at the base
first, then judges HEAD with the ratchet's --base-clippy-json: a crate the base already
has over its row is red only for hits HEAD adds. cmux-next fast gates use it on a pull
request merged with a tip whose baseline went down since the pull request's own ratchet
ran (cmux_next_fast_gates.py), so a base ratchet red never reads as the pull request's.
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
    # The ratchet's source, measured baseline, and plan are workspace-wide inputs.
    # A baseline-only change must run the ratchet rather than taking the no-package fast path.
    "scripts/cmux-next/rust_panic_ratchet.py",
    "scripts/cmux-next/rust-panic-baseline.json",
    "plans/cmux-next/rust-panic-free.md",
})
RATCHET = "scripts/cmux-next/rust_panic_ratchet.py"
LIB_KINDS = frozenset({"lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro"})


def workspace_of(repo: Path) -> tuple[dict[str, str], dict[str, set[str]], set[str]]:
    """The members' directories (repository-relative) with their package names, each
    member's dependents (the members naming it as a path dependency of any kind), and
    the members with a library target."""
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
    libs = {package["name"] for package in packages
            if any(LIB_KINDS & set(target.get("kind", [])) for target in package.get("targets", []))}
    return names, dependents, libs


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
    parser.add_argument("--panic-ratchet", type=Path, metavar="JSONL",
                        help="run the panic ratchet on the selected packages, writing clippy's JSON here")
    parser.add_argument("--compare-base", action="store_true",
                        help="with --panic-ratchet: lint the base too; a count the base reaches is the base's red")
    args = parser.parse_args(argv)
    repo = (args.repo or Path(fmt_changed.git(Path.cwd(), "rev-parse", "--show-toplevel").strip())).resolve()
    known = fmt_changed.packages(repo)
    try:
        workspace, dependents, libs = workspace_of(repo)
    except subprocess.CalledProcessError:
        print("::error title=cmux-tui clippy::`cargo metadata --no-deps` failed in cmux-tui (its error is above); "
              "fix the manifest it names")
        return 1
    base = args.base.strip()
    paths = fmt_changed.changed(repo, base)
    compare = base if args.compare_base and paths is not None else ""
    ratchet_inputs_changed = False
    if args.panic_ratchet and base and set(base) != {"0"}:
        try:
            all_changed = [path for path in fmt_changed.git(repo, "diff", "--name-only", "-z", base, "HEAD").split("\0") if path]
            ratchet_inputs_changed = any(path in WHOLE_WORKSPACE for path in all_changed)
        except subprocess.CalledProcessError:
            ratchet_inputs_changed = True
    if paths is None or ratchet_inputs_changed or any(path in WHOLE_WORKSPACE for path in paths):
        if args.panic_ratchet:
            return panic_ratchet(repo, ["--workspace"], True, "the whole cmux-tui workspace", args.panic_ratchet, compare)
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
        if args.panic_ratchet:
            return panic_ratchet(repo, packages, any(name in libs for name in selected), ", ".join(selected),
                                 args.panic_ratchet, compare)
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


def panic_ratchet(repo: Path, packages: list[str], has_lib: bool, scope: str, out: Path, compare: str = "") -> int:
    """Lint the production targets of `packages` with the ratchet's flags into `out`, then let
    the ratchet judge them. Cargo refuses `--lib` when no selected package has a library.
    With `compare` (a base commit) the same lint runs there first, into `<out>.base`, and the
    ratchet charges HEAD only for counts the base does not reach."""
    ratchet = repo / RATCHET
    flags = subprocess.run([sys.executable, str(ratchet), "--flags"], check=True,
                           stdout=subprocess.PIPE, text=True).stdout.split()
    targets = ["--lib", "--bins"] if has_lib else ["--bins"]
    command = ["cargo", "clippy", "--locked", *packages, *targets, "--message-format=json", "--", *flags]
    out.parent.mkdir(parents=True, exist_ok=True)
    judge = [sys.executable, str(ratchet), "--repo", str(repo), "--clippy-json", str(out)]
    if compare:
        base_out = out.with_name(out.name + ".base")
        head = fmt_changed.git(repo, "rev-parse", "HEAD").strip()
        print(f"cmux-tui-clippy-changed: panic ratchet on {scope} at the base {compare}", flush=True)
        print(" ".join(command), flush=True)
        # The same checkout, so the HEAD run after it rebuilds only what the change touches.
        fmt_changed.git(repo, "checkout", "--quiet", "--detach", compare)
        try:
            with base_out.open("w", encoding="utf-8") as handle:
                subprocess.run(command, cwd=repo / ROOT, stdout=handle)
        finally:
            fmt_changed.git(repo, "checkout", "--quiet", "--detach", head)
        judge += ["--base-clippy-json", str(base_out)]
    print(f"cmux-tui-clippy-changed: panic ratchet on {scope}", flush=True)
    print(" ".join(command), flush=True)
    with out.open("w", encoding="utf-8") as handle:
        subprocess.run(command, cwd=repo / ROOT, stdout=handle)
    # The ratchet refuses a run with no build-finished success line, so a failed build is red there.
    rc = subprocess.run(judge).returncode
    if rc:
        print(f"::error title=cmux-tui panic ratchet::the panic ratchet is red for {scope}; "
              f"its log above names each new hit (plans/cmux-next/rust-panic-free.md)")
    return 1 if rc else 0


if __name__ == "__main__":
    sys.exit(main())
