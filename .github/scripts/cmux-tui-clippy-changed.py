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
lints the whole workspace. Packages in a workspace of their own (the app FFI
workspace with cmux-rd-ffi, cmux-rd-host, ...) and vendored crates are not members and stay with
cmux-tui.yml's dispatch run. Which files map to which package is
cmux-tui-fmt-changed.py's rule, shared from there.

--panic-ratchet JSONL runs the panic ratchet (scripts/cmux-next/rust_panic_ratchet.py,
plans/cmux-next/rust-panic-free.md) on the same packages instead: their production
targets (--lib --bins) are linted with the ratchet's flags into JSONL, and the ratchet
judges the counts against the baseline at HEAD. Only cmux-tui.yml ran it before, so
#27935 landed two acpmux indexing_slicing hits that turned base red. A crate the run
does not check keeps its baseline (the ratchet names it in a warning).

--compare-base (with --panic-ratchet and a base): when HEAD is over the baseline, it lints
the same packages at the base too, then judges HEAD with the ratchet's --base-clippy-json:
a crate the base already has over its row is red only for hits HEAD adds. A HEAD within the
baseline is green without the base lint, which could only excuse counts. cmux-next fast gates use it on a pull
request merged with a tip whose baseline went down since the pull request's own ratchet
ran (cmux_next_fast_gates.py), so a base ratchet red never reads as the pull request's.

A stale lockfile is named as such: when cargo refuses to update a Cargo.lock under --locked,
no lint ran, so the lint and ratchet messages would send the reader to fix lints that do not
exist (#42133 went red on 15 checks for a thiserror bump on the base, and its lane reran this
job twice). The error then names the lockfile and `scripts/cmux-next/cargo-locks.py fix`.
"""

from __future__ import annotations

import argparse
from collections import deque
import importlib.util
import json
from pathlib import Path
import re
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
# Cargo's own words for a Cargo.lock that no longer matches its manifests under --locked: each spelling
# scripts/cmux-next/cargo-locks.py knows (cargo changed the sentence, and a missing lock is "create").
STALE_LOCK = re.compile(r"(?:cannot (?:update|create) the lock file|the lock file) (?P<path>\S+) "
                        r"(?:because|needs to be updated but) --locked was passed")


def stale_lock(line: str, repo: Path) -> str | None:
    """The repository-relative lockfile a cargo stderr line refuses to update under --locked, or None."""
    if (found := STALE_LOCK.search(line)) is None:
        return None
    path = Path(found["path"])
    try:
        return path.resolve().relative_to(repo.resolve()).as_posix()
    except ValueError:
        return found["path"]


def stale_lock_error(title: str, lock: str) -> str:
    """The annotation for a run cargo stopped at a stale lockfile: no lint ran, so a rerun or a lint fix cannot help."""
    return (f"::error title={title} (stale Cargo.lock)::{lock} does not match its manifests on this merge ref (often: "
            f"the base changed a dependency after the branch was cut), so cargo --locked stopped before any lint ran. "
            f"Merge the base branch into the branch, run `scripts/cmux-next/cargo-locks.py fix` from the repository "
            f"root and commit the Cargo.lock files it changed; rerunning the job does not help")


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
    rc, red_files, lock = run_clippy(command, repo / ROOT, repo)
    if rc and lock:
        print(stale_lock_error("cmux-tui clippy", lock))
    elif rc:
        print(f"::error title=cmux-tui clippy::clippy -D warnings failed for {scope}; "
              f"run `{' '.join(command)}` in cmux-tui and fix each lint (an allow needs a comment saying why)")
        name_base_reds(repo, base if paths is not None else "", red_files)
    return 1 if rc else 0


def run_clippy(command: list[str], cwd: Path, repo: Path) -> tuple[int, list[str], str | None]:
    """Run clippy with its output passed through as it comes, and return its exit code with the
    files its errors point at (`--> crates/x/src/y.rs:1:2`, relative to cmux-tui), in order, and
    the lockfile cargo refused to update under --locked, if any."""
    files: list[str] = []
    lock = None
    process = subprocess.Popen(command, cwd=cwd, stderr=subprocess.PIPE, text=True, errors="replace")
    assert process.stderr is not None
    for line in process.stderr:
        sys.stderr.write(line)
        if (path := red_file(line)) and path not in files:
            files.append(path)
        lock = lock or stale_lock(line, repo)
    sys.stderr.flush()
    return process.wait(), files, lock


def red_file(line: str) -> str | None:
    """The file of a diagnostic's `-->` line, or None."""
    rest = line.strip()
    if not rest.startswith("--> "):
        return None
    location = rest[4:].strip()
    # path:line:col; a Windows drive or a colon in the path keeps all but the last two fields.
    parts = location.rsplit(":", 2)
    return parts[0] if len(parts) == 3 and parts[1].isdigit() else None


def name_base_reds(repo: Path, base: str, red_files: list[str]) -> None:
    """Say which red files the change does not touch, and the base commit that last changed each.

    #40242 merged to feat-cmux-next with eight clippy errors in cmux-tui/src/cli/ext*.rs; every
    pull request that touched cmux-tui then failed this step with a message naming its own
    packages, and four of them were read as the pull request's own red. A red file outside the
    diff is the base's: the fix is a base-red pull request, not a change to this one."""
    if not base or set(base) == {"0"} or not red_files:
        return
    try:
        changed = {path for path in fmt_changed.git(repo, "diff", "--name-only", "-z", base, "HEAD").split("\0") if path}
    except subprocess.CalledProcessError:
        return
    outside = [path for path in red_files if f"{ROOT}/{path}" not in changed]
    for path in outside:
        try:
            last = fmt_changed.git(repo, "log", "-1", "--format=%h %s", base, "--", f"{ROOT}/{path}").strip()
        except subprocess.CalledProcessError:
            last = ""
        since = f" (last changed on the base by {last})" if last else ""
        print(f"::error title=cmux-tui clippy (base red)::{ROOT}/{path} is red and this change does not touch it: "
              f"most likely the base {base[:12]} already fails here{since}. Then fix it on the base branch in its own "
              f"pull request and update this one once that lands (a lint this change causes in an untouched file, "
              f"through an API it changed, is this change's to fix)")
    if outside and len(outside) == len(red_files):
        print("cmux-tui-clippy-changed: every clippy error is in a file this change does not touch: likely a base red")


def panic_ratchet(repo: Path, packages: list[str], has_lib: bool, scope: str, out: Path, compare: str = "") -> int:
    """Lint the production targets of `packages` with the ratchet's flags into `out`, then let
    the ratchet judge them. Cargo refuses `--lib` when no selected package has a library.
    With `compare` (a base commit) a HEAD the baseline already passes is green as it stands:
    the base run only excuses counts over the baseline, so it cannot change that verdict. Only
    a red HEAD lints the base too, into `<out>.base`, and the ratchet then charges HEAD only for
    counts the base does not reach. On a green PR that skips one lint of the changed packages
    (80 s of the job's 6 min on #37445, run 42334950081)."""
    ratchet = repo / RATCHET
    flags = subprocess.run([sys.executable, str(ratchet), "--flags"], check=True,
                           stdout=subprocess.PIPE, text=True).stdout.split()
    targets = ["--lib", "--bins"] if has_lib else ["--bins"]
    command = ["cargo", "clippy", "--locked", *packages, *targets, "--message-format=json", "--", *flags]
    out.parent.mkdir(parents=True, exist_ok=True)
    # Cargo's stderr is kept beside the JSON so the ratchet can name a stale lockfile as the cause.
    cargo_log = out.with_name(out.name + ".stderr")
    judge = [sys.executable, str(ratchet), "--repo", str(repo), "--clippy-json", str(out),
             "--cargo-log", str(cargo_log)]
    print(f"cmux-tui-clippy-changed: panic ratchet on {scope}", flush=True)
    print(" ".join(command), flush=True)
    with out.open("w", encoding="utf-8") as handle, cargo_log.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(command, cwd=repo / ROOT, stdout=handle, stderr=subprocess.PIPE,
                                   text=True, errors="replace")
        assert process.stderr is not None
        lock = None
        for line in process.stderr:
            sys.stderr.write(line)
            log.write(line)
            lock = lock or stale_lock(line, repo)
        sys.stderr.flush()
        process.wait()
    # The ratchet refuses a run with no build-finished success line, so a failed build is red there.
    if compare:
        strict = subprocess.run(judge, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if strict.returncode == 0:
            print(strict.stdout, end="", flush=True)
            print(f"cmux-tui-clippy-changed: HEAD passes the baseline, so the base {compare} is not linted", flush=True)
            return 0
        base_out = out.with_name(out.name + ".base")
        head = fmt_changed.git(repo, "rev-parse", "HEAD").strip()
        print(f"cmux-tui-clippy-changed: HEAD is over the baseline; panic ratchet on {scope} at the base {compare}",
              flush=True)
        print(" ".join(command), flush=True)
        fmt_changed.git(repo, "checkout", "--quiet", "--detach", compare)
        try:
            with base_out.open("w", encoding="utf-8") as handle:
                subprocess.run(command, cwd=repo / ROOT, stdout=handle)
        finally:
            fmt_changed.git(repo, "checkout", "--quiet", "--detach", head)
        judge += ["--base-clippy-json", str(base_out)]
    rc = subprocess.run(judge).returncode
    if rc and lock:
        print(stale_lock_error("cmux-tui panic ratchet", lock))
    elif rc:
        print(f"::error title=cmux-tui panic ratchet::the panic ratchet is red for {scope}; "
              f"its log above names each new hit (plans/cmux-next/rust-panic-free.md)")
    return 1 if rc else 0

if __name__ == "__main__":
    sys.exit(main())
