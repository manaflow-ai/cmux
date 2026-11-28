#!/usr/bin/env python3
"""Run `cargo clippy --all-targets` on each cmux-tui workspace package a change touches; only compile errors fail.

Usage: cmux-tui-clippy-changed.py [--repo ROOT] [--base SHA] [--panic-ratchet JSONL [--compare-base]]

PR CI never runs cmux-tui.yml (dispatch only), whose workspace clippy is the
only `--all-targets` lint of cmux-tui, and the fast tier's cargo entries only
run tests. So #23163 and #23372 landed clippy reds in cmux-tui/crates/cmux-tui/tests/
and broke base clippy for everyone. This lints the cmux-tui workspace members
owning a changed .rs file or Cargo.toml between --base and HEAD (tests, benches
and examples included), plus every member that depends on one of them, in one
`cargo clippy --keep-going` so each red package is reported. Members and their
path dependencies come from `cargo metadata --no-deps`. A change to the workspace
manifest or the lockfile is read, not taken as everything: a Cargo.lock change reaches
each member whose own entry changed or that uses (through any crate) an entry added,
removed or bumped; a manifest change reaches new members and the users of a changed
`[workspace.dependencies]` entry (default-members and non-dev/test profiles reach none).
Any other manifest table (lints, dev/test profile, patch, workspace.package), an unreadable
or reformatted lock, a clippy config, the toolchain pin, or no usable base lints the
whole workspace. Post-merge calls lint since the plan's base (the last judged batch);
before, they passed no base and every one linted all 225 members (job 140499897736,
15.8 min); 18 of the 22 batch windows on 11-26..27 touched the lock or the manifest. Packages in a workspace of their own (the app FFI
workspace with cmux-rd-ffi, cmux-rd-host, ...) and vendored crates are not members and stay with
cmux-tui.yml's dispatch run. Which files map to which package is
cmux-tui-fmt-changed.py's rule, shared from there.

--panic-ratchet JSONL runs the panic ratchet (scripts/cmux-next/rust_panic_ratchet.py,
plans/cmux-next/rust-panic-free.md) on the same packages instead: their production
targets (--lib --bins) are linted with the ratchet's flags into JSONL, and the ratchet
judges the counts against the baseline at HEAD. Only cmux-tui.yml ran it before, so
#27935 landed two acpmux indexing_slicing hits that turned base red. A crate the run
does not check keeps its baseline (the ratchet names it in a warning).

The clippy run passes clippy the ratchet's flags too (`-- <ratchet flags> --cap-lints warn`, the ratchet's own
argument list), so the ratchet's run after it finds every lib and bin unit fresh and cargo replays their cached
JSON instead of checking them again. Clippy keeps its arguments in each workspace unit's fingerprint, so with two
argument lists the target kept flipping: in 23 pool clippy-changed steps on 2026-11-27 the ratchet re-checked 155
of the 160 workspace crates the clippy step had just checked, 267 s median and 5,042 s in all (44% of the step).
The clippy step neither prints nor annotates the ratchet's lint codes (RATCHET_LINTS: they are the ratchet's to
judge, and lints never fail this step), so its output and verdict are what they were. The ratchet keeps its own
`--lib --bins` run because cargo's JSON does not say which messages came from a crate's test build (`target.test`
says only that a target is tested by default), so a filter of the --all-targets run would count test code. Leo:
"cache, fast, the whole nine yards"; "Okay, surely we don't need to do that many Linux builds, do we?".

The ratchet's run adds `--examples` (ratchet_targets) so it resolves features as the --all-targets run did. Cargo's
resolver 2 turns on dev-dependency features only when a run selects a dev target (tests, examples or benches), so
`--lib --bins` built every unit a dev-dependency reaches with other features, under other hashes, and checked them
again in spite of the shared flags: job 140844832708 (run 46101326583, 2026-11-28) spent 324 s of its 1,158 s
re-checking 56 units, zbus, zvariant and iroh among them, and the cmux-tui-core, cmux-terminal-client and acpmux-tui
chain. With `--examples` the run is fresh and cargo replays it. Example units' messages say `"kind": ["example"]`
and the ratchet skips them, so it still counts lib and bin code only. Leo: "de facto, im asking for 99% fewer
minutes of ci time, period." "whatever we need to cut, we cut."

--compare-base (with --panic-ratchet and a base): when HEAD is over the baseline, it lints
the same packages at the base too, then judges HEAD with the ratchet's --base-clippy-json:
a crate the base already has over its row is red only for hits HEAD adds. A HEAD within the
baseline is green without the base lint, which could only excuse counts, and so is a HEAD whose every count
over the baseline has all its hits in files the change does not touch (the ratchet's --untouched-is-base:
the base's drift, which the base lint would only excuse). cmux-next fast gates use it on a pull
request merged with a tip whose baseline went down since the pull request's own ratchet
ran (cmux_next_fast_gates.py), so a base ratchet red never reads as the pull request's.

A stale lockfile is named as such: when cargo refuses to update a Cargo.lock under --locked,
no lint ran, so the lint and ratchet messages would send the reader to fix lints that do not
exist (#42133 went red on 15 checks for a thiserror bump on the base, and its lane reran this
job twice). The error then names the lockfile and `scripts/cmux-next/cargo-locks.py fix`.

Lints never fail the check (Leo, 2026-11-20, after two base clippy lints turned this required check red on
every feat-cmux-next pull request: "WHY IS LINT EVEN STOPPING SHIT INSTEAD OF JUST BEING OOPS"). Clippy runs
with `--cap-lints warn`, so every lint, even one a crate denies with `#![deny]` or a Cargo `[lints]` table,
is a warning; each one is printed as a `::warning file=...` annotation and listed in the step summary, and
the lint is fixed forward. The check fails only when the code does not build: a rustc error (an `E` code or
no code), a failed `cargo metadata`, or a stale lockfile. The panic ratchet (--panic-ratchet) still fails on
a new panic site: it guards against crashes in production code, not style.

A base red costs no whole run. cmux-tui-clippy-seed.yml's whole-workspace run records which members its commit fails
to compile (CMUX_CLIPPY_VERDICT_OUT, write_verdict()), with the ids of everything each red rests on; a pull request's
step reads the newest one (CMUX_CLIPPY_BASE_VERDICT, scripts/ci/clippy-base-seed.sh verdict) and neither lints nor
ratchet-judges a member it does not touch that is red there with the same inputs at its base (or a user of such a
member's library). The members it touches are linted and judged as before, and the step prints the base-red notice
beside their own pass or fail. Before, the step learned of the base red only after its whole run: 32% of 60 failed
clippy-changed steps sampled on 2026-11-27 ended in a base red, ~12 min each.

--autofixed-ok HEAD_SHA (feat-cmux-next pull requests, while vars.CMUX_PR_AUTOFIX_PUSH is 1): a red that
the PR autofix repairs is not a red (with lints capped, the red this still covers is one no JSON
diagnostic explains, such as a lint cargo stopped on). The job applies what cmux-next-pr-autofix.yml applies
(scripts/cmux-next/autofix-clippy.sh: `cargo clippy --fix --all-targets` on the packages owning the
changed .rs files, then `cargo fmt` on them), keeps only the files the pull request changes (what
pr-autofix-apply.sh --changed lets the push carry) and lints again. Green then: the job passes with an
"autofixed" notice, and the PR autofix push (cmux-next-pr-autofix-push.yml on main) brings the fix
commit, whose own run lints strictly. A head that is already an autofix commit (an Autofix-Run trailer),
or a red the fix leaves, fails as before. 11-13..19: clippy was one of the mechanical-only reds on 793
PR heads (cmuxterm-hq docs/ci/bottleneck-and-skip-candidates-2026-11-21.md, section 3). Leo: "WHY IS
LINT EVEN STOPPING SHIT INSTEAD OF JUST BEING OOPS".
"""

from __future__ import annotations

import argparse
from collections import defaultdict, deque
import fnmatch
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import tomllib
from typing import NamedTuple


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
# The workspace manifest and the lockfile are read, not taken as "every member" (narrowed()).
MANIFEST, LOCKFILE = f"{ROOT}/Cargo.toml", f"{ROOT}/Cargo.lock"
EVERY_MEMBER = WHOLE_WORKSPACE - {MANIFEST, LOCKFILE}
# The root package's own tables in the workspace manifest (the root is a package too): a change there is the root
# package's own change.
PACKAGE_TABLES = frozenset({"package", "lib", "bin", "test", "bench", "example", "dependencies", "dev-dependencies",
                            "build-dependencies", "target", "features", "lints", "badges"})
# The profiles a `cargo clippy --all-targets` unit can be built with (test inherits dev).
CHECK_PROFILES = frozenset({"dev", "test"})
RATCHET = "scripts/cmux-next/rust_panic_ratchet.py"
# Every lint is a warning, whatever level a crate or a Cargo [lints] table gives it; only compile errors fail.
CAP_LINTS = ["--cap-lints", "warn"]
# rustc's own error codes; a lint's code is its name (`clippy::needless_return`, `dead_code`).
COMPILE_ERROR_CODE = re.compile(r"^E\d{4}$")
# cargo's and rustc's closing lines after errors: they say how many, not what, so they never decide the verdict.
ERROR_SUMMARY = re.compile(r"^(?:aborting due to |could not compile |\d+ previous errors?)")
CARGO_ERROR = re.compile(r"^error(?:\[|: )")
MAX_ANNOTATIONS = 50
LIB_KINDS = frozenset({"lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro"})
# Cargo's own words for a Cargo.lock that no longer matches its manifests under --locked: each spelling
# scripts/cmux-next/cargo-locks.py knows (cargo changed the sentence, and a missing lock is "create").
STALE_LOCK = re.compile(r"(?:cannot (?:update|create) the lock file|the lock file) (?P<path>.+?) "
                        r"(?:because|needs to be updated but) --locked was passed")


def ratchet_flags(repo: Path) -> list[str]:
    """The ratchet's clippy flags (`-W clippy::...` pairs), or none when this checkout has no ratchet to ask."""
    ratchet = repo / RATCHET
    if not ratchet.is_file():
        return []
    try:
        return subprocess.run([sys.executable, str(ratchet), "--flags"], check=True,
                              stdout=subprocess.PIPE, text=True).stdout.split()
    except (OSError, subprocess.CalledProcessError):
        return []


def lint_args(flags: list[str]) -> list[str]:
    """The clippy run's arguments: its targets, and after `--` the ratchet's flags and the lint cap, in the
    ratchet's order, so the two runs share each unit's fingerprint (see the module docstring)."""
    return ["--all-targets", "--message-format=json", "--", *flags, *CAP_LINTS]


def flag_lints(flags: list[str]) -> frozenset[str]:
    """The lint codes `-W` FLAGS turn on (`clippy::unwrap_used`, ...)."""
    return frozenset(lint for flag, lint in zip(flags, flags[1:]) if flag == "-W")


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


def workspace_of(repo: Path) -> tuple[dict[str, str], dict[str, set[str]], set[str], dict[str, set[str]],
                                     dict[str, set[str]]]:
    """The members' directories (repository-relative) with their package names, each
    member's dependents (the members naming it as a path dependency of any kind),
    the members with a library target, the members using each dependency key
    (its `rename` or name, as `[workspace.dependencies]` keys it), and each member's
    path dependencies' directories (repository-relative, members or not)."""
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
    uses: dict[str, set[str]] = defaultdict(set)
    requires: dict[str, set[str]] = {name: set() for name in names.values()}
    for package in packages:
        for dependency in package["dependencies"]:
            uses[dependency.get("rename") or dependency["name"]].add(package["name"])
            if dependency.get("path"):
                where = Path(dependency["path"]).resolve()
                if where.is_relative_to(top):
                    requires[package["name"]].add(where.relative_to(top).as_posix())
            target = by_dir.get(Path(dependency["path"]).resolve()) if dependency.get("path") else None
            if target and target != package["name"]:
                dependents[target].add(package["name"])
    libs = {package["name"] for package in packages
            if any(LIB_KINDS & set(target.get("kind", [])) for target in package.get("targets", []))}
    return names, dependents, libs, uses, requires


def at(repo: Path, rev: str, path: str) -> str:
    """PATH's text at REV ("" when it is not there)."""
    try:
        return fmt_changed.git(repo, "show", f"{rev}:{path}")
    except subprocess.CalledProcessError:
        return ""


def load_toml(text: str) -> dict | None:
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError:
        return None


def package_tables(doc: dict) -> dict:
    return {key: value for key, value in doc.items() if key in PACKAGE_TABLES}


def manifest_change(before: str, after: str, workspace: dict[str, str], uses: dict[str, set[str]]) -> set[str] | None:
    """The members a change to the workspace manifest reaches, or None when it can reach every member.
    Most of its changes add a member or a `[workspace.dependencies]` entry (38 of the 3,302 feat-cmux-next
    commits on 11-25..27 touched it): those reach the new members and the members using a changed entry;
    default-members and the release and custom profiles reach none. A change to any other workspace table
    (lints, the dev and test profiles, patches, workspace.package, exclude) reaches every member. The root package's own tables are left out here: a change there is the root package's own."""
    old, new = load_toml(before), load_toml(after)
    if old is None or new is None:
        return None

    def rest(doc: dict) -> dict:
        doc = {key: value for key, value in doc.items() if key not in PACKAGE_TABLES}
        # default-members only picks the packages a bare `cargo` command builds (this check always names them).
        doc["workspace"] = {key: value for key, value in (doc.get("workspace") or {}).items()
                            if key not in ("members", "default-members", "dependencies")}
        # Clippy builds with the dev profile (its log ends "Finished `dev` profile"): a release or custom
        # profile changes no unit it checks (2c789b93f17f..5af1e1c79eb2 changed only [profile.release]).
        doc["profile"] = {name: value for name, value in (doc.get("profile") or {}).items() if name in CHECK_PROFILES}
        return doc

    if rest(old) != rest(new):
        return None
    reached: set[str] = set()
    old_ws, new_ws = old.get("workspace") or {}, new.get("workspace") or {}
    added = set(new_ws.get("members") or []) - set(old_ws.get("members") or [])
    for path, name in workspace.items():
        relative = path[len(ROOT) + 1:] if path.startswith(f"{ROOT}/") else ""
        if relative and any(fnmatch.fnmatchcase(relative, pattern.rstrip("/")) for pattern in added):
            reached.add(name)
    old_deps, new_deps = old_ws.get("dependencies") or {}, new_ws.get("dependencies") or {}
    for key in old_deps.keys() | new_deps.keys():
        if old_deps.get(key) != new_deps.get(key):
            reached |= uses.get(key, set())
    return reached


def lock_graph(doc: dict) -> tuple[dict[tuple, tuple], dict[tuple, set[tuple]]]:
    """Each Cargo.lock entry, (name, version, source), with what decides its build (checksum and
    dependencies), and each entry's users."""
    entries = doc.get("package") or []
    keys = [(entry["name"], entry.get("version", ""), entry.get("source", "")) for entry in entries]
    by_name: dict[str, list[tuple]] = defaultdict(list)
    for key in keys:
        by_name[key[0]].append(key)
    state: dict[tuple, tuple] = {}
    users: dict[tuple, set[tuple]] = defaultdict(set)
    for key, entry in zip(keys, entries):
        dependencies = entry.get("dependencies") or []
        state[key] = (entry.get("checksum", ""), tuple(sorted(dependencies)))
        for dependency in dependencies:
            name, _, rest = dependency.partition(" ")
            version = rest.split(" ")[0]
            for target in by_name.get(name, ()):
                if not version or target[1] == version:
                    users[target].add(key)
    return state, users


def lock_change(before: str, after: str, members: set[str]) -> set[str] | None:
    """The members a Cargo.lock change reaches: each whose own entry changed (a dependency added or dropped)
    or that uses, directly or through other crates, an entry added, removed or changed (a version bump, a
    new checksum). None when either lock cannot be read or its format changed. 74 of the 3,302
    feat-cmux-next commits on 11-25..27 touched the lock, so nearly every post-merge window did."""
    old, new = load_toml(before), load_toml(after)
    if old is None or new is None:
        return None
    if {k: v for k, v in old.items() if k != "package"} != {k: v for k, v in new.items() if k != "package"}:
        return None
    old_state, old_users = lock_graph(old)
    new_state, new_users = lock_graph(new)
    changed = {key for key in old_state.keys() | new_state.keys() if old_state.get(key) != new_state.get(key)}
    seen, queue = set(changed), deque(changed)
    while queue:
        key = queue.popleft()
        for user in old_users.get(key, set()) | new_users.get(key, set()):
            if user not in seen:
                seen.add(user)
                queue.append(user)
    return {name for name, _, source in seen if not source and name in members}


def narrowed(repo: Path, base: str, paths: list[str], workspace: dict[str, str],
             uses: dict[str, set[str]]) -> set[str] | None:
    """The members the change's edits to the workspace manifest and Cargo.lock reach (none when it has
    neither), or None when one of them can reach every member."""
    reached: set[str] = set()
    if MANIFEST in paths:
        found = manifest_change(at(repo, base, MANIFEST), at(repo, "HEAD", MANIFEST), workspace, uses)
        if found is None:
            return None
        reached |= found
    if LOCKFILE in paths:
        found = lock_change(at(repo, base, LOCKFILE), at(repo, "HEAD", LOCKFILE), set(workspace.values()))
        if found is None:
            return None
        reached |= found
    return reached


def root_package_changed(repo: Path, base: str) -> bool:
    """Whether the root package's own tables in the workspace manifest differ from the base's."""
    old, new = load_toml(at(repo, base, MANIFEST)), load_toml(at(repo, "HEAD", MANIFEST))
    return old is None or new is None or package_tables(old) != package_tables(new)


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
    parser.add_argument("--autofixed-ok", default="", metavar="HEAD_SHA",
                        help="the pull request head: a red the PR autofix repairs passes as autofixed")
    parser.add_argument("--compare-base", action="store_true",
                        help="with --panic-ratchet: lint the base too; a count the base reaches is the base's red")
    args = parser.parse_args(argv)
    repo = (args.repo or Path(fmt_changed.git(Path.cwd(), "rev-parse", "--show-toplevel").strip())).resolve()
    known = fmt_changed.packages(repo)
    flags = ratchet_flags(repo)
    args_for_lint, hidden = lint_args(flags), flag_lints(flags)
    try:
        workspace, dependents, libs, uses, requires = workspace_of(repo)
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
            ratchet_inputs_changed = any(path in EVERY_MEMBER for path in all_changed)
        except subprocess.CalledProcessError:
            ratchet_inputs_changed = True
    reached = None if paths is None else narrowed(repo, base, paths, workspace, uses)
    skipped: list[str] = []
    base_reds: dict[str, dict] = {}
    verdict_sha = ""
    if paths is None or reached is None or ratchet_inputs_changed or any(path in EVERY_MEMBER for path in paths):
        if args.panic_ratchet:
            return panic_ratchet(repo, ["--workspace"], True, "the whole cmux-tui workspace", args.panic_ratchet, compare,
                                 libs)
        command = ["cargo", "clippy", "--locked", "--keep-going", "--workspace", *args_for_lint]
        scope = "the whole cmux-tui workspace"
    else:
        # The workspace manifest is the root package's manifest too: it is the root package's change only when
        # the package's own tables differ (narrowed() read the workspace's).
        own = [path for path in paths if path != MANIFEST or root_package_changed(repo, base)]
        touched = fmt_changed.touched(own, known, fmt_changed.manifest_dirs(repo, base))
        for path in sorted(touched - workspace.keys()):
            print(f"cmux-tui-clippy-changed: {path} is not a cmux-tui workspace member (cmux-tui.yml lints it)")
        changed = {workspace[path] for path in touched if path in workspace}
        if via_manifest := sorted(reached - changed):
            print(f"cmux-tui-clippy-changed: the workspace manifest or Cargo.lock change reaches {', '.join(via_manifest)}")
        changed |= reached
        if not changed:
            print("cmux-tui-clippy-changed: no cmux-tui workspace package changed")
            return 0
        selected = sorted(with_dependents(changed, dependents))
        if users := [name for name in selected if name not in changed]:
            print(f"cmux-tui-clippy-changed: {', '.join(users)} depend on {', '.join(sorted(changed))}")
        # A member this change does not touch that the base already fails to compile (the recorded verdict) is
        # not linted again: it would only fail the step, after the whole run, with a base red (32% of the 60 failed
        # clippy-changed steps sampled on 2026-11-27 ended so, ~12 min each). The members it touches still are.
        base_reds, verdict_sha = trusted_base_reds(repo, base, workspace)
        if skipped := base_red_skips(selected, changed, base_reds, dependents):
            selected = [name for name in selected if name not in skipped]
            print(f"cmux-tui-clippy-changed: {', '.join(skipped)} already fail(s) to compile on the base "
                  f"{base[:12]} (verdict recorded at {verdict_sha[:12]}) and this change does not touch them: "
                  f"not linted", flush=True)
            if not selected:
                report_base_red_skips(skipped, base_reds, dependents, base, verdict_sha, "", True)
                return 0
        packages = [arg for name in selected for arg in ("-p", name)]
        if args.panic_ratchet:
            return panic_ratchet(repo, packages, any(name in libs for name in selected), ", ".join(selected),
                                 args.panic_ratchet, compare, libs)
        command = ["cargo", "clippy", "--locked", "--keep-going", *packages, *args_for_lint]
        scope = ", ".join(selected)
    print(f"cmux-tui-clippy-changed: linting {scope}", flush=True)
    print(" ".join(command), flush=True)
    # From cmux-tui/ so rustup uses its rust-toolchain.toml pin and cargo its workspace.
    text: list[str] = []
    lint_started = time.monotonic()
    result = run_clippy(warnings_soft(command, repo), repo / ROOT, repo, text, hidden)
    lint_seconds = time.monotonic() - lint_started
    report_lints(result.lints, scope)
    if paths is None and (verdict_out := os.environ.get("CMUX_CLIPPY_VERDICT_OUT")):
        # cmux-tui-clippy-seed.yml on feat-cmux-next: the whole workspace's verdict, which pull requests read.
        write_verdict(repo, Path(verdict_out), result, workspace, requires)
    if result.rc and (killed := killed_units(text)):
        # A unit the kernel killed (SIGKILL: the runner ran out of memory) is no lint and no code error: the
        # autofix below cannot repair it, and its `clippy --fix` rebuilt every unit for ~23 min until the job's
        # 40-min cap cancelled it with no verdict and no cache save (141020758253, 2026-11-28).
        print(f"::error title=cmux-tui clippy::the compiler was killed ({killed[0]}) on "
              f"{', '.join(killed[1:]) or 'a unit'} for {scope}: the runner ran out of memory, not a code error. "
              f"Rerun the job; the autofix was not tried (it cannot repair a kill)")
        if skipped:
            report_base_red_skips(skipped, base_reds, dependents, base, verdict_sha, scope, False)
        return 1
    if result.rc and not result.lock and args.autofixed_ok and paths is not None and autofix_fits(lint_seconds) \
            and autofixed(repo, command, paths, workspace, args.autofixed_ok):
        return 0
    if result.rc and result.lock:
        print(stale_lock_error("cmux-tui clippy", result.lock))
        return 1
    if result.rc and not result.compile_errors and result.lint_errors:
        # Cargo stopped only on lints (a level --cap-lints did not reach): a lint is never a stop.
        print(f"::warning title=cmux-tui clippy::cargo exited {result.rc} on lints only for {scope}; "
              f"lints never fail this check, so it passes (fix them forward)")
        return 0
    rc, red_files = result.rc, result.red_files
    if rc and (oops := load_isolate(repo)):
        # ci-oops fault isolation: on a pull request, an optional member (scripts/ci/oops/optional-units.json)
        # that alone fails is left out, the rest is linted again, and a CI_OOPS line asks for the follow-up.
        def again(argv: list[str]) -> tuple[int, str]:
            nonlocal red_files
            print(" ".join(argv), flush=True)
            out: list[str] = []
            run = run_clippy(warnings_soft(argv, repo), repo / ROOT, repo, out, hidden)
            report_lints(run.lints, scope)
            red_files = run.red_files
            lints_only = run.rc and not run.lock and not run.compile_errors and run.lint_errors
            return (0 if lints_only else run.rc), "".join(out)

        rc, _ = oops.isolated_run("cargo-member", command, runner=again, first=(rc, "".join(text)))
    if skipped:
        report_base_red_skips(skipped, base_reds, dependents, base, verdict_sha, scope, not rc)
    if rc:
        print(f"::error title=cmux-tui clippy::clippy found compile errors in {scope}; "
              f"run `{' '.join(command)}` in cmux-tui and fix each error (lints alone never fail this check)")
        name_base_reds(repo, base if paths is not None else "", red_files)
        return 1
    return 0


KILLED = re.compile(r"\(signal: (\d+), (SIG[A-Z]+)")
KILLED_UNIT = re.compile(r"^error: could not compile `([^`]+)` \(([^)]+)\)")


def killed_units(text: list[str]) -> list[str]:
    """[signal, unit, ...] when the run's compiler was killed by a signal (`process didn't exit successfully:
    ... (signal: 9, SIGKILL: kill)`), else []. The units are cargo's `could not compile` lines just before it."""
    units: list[str] = []
    signal = ""
    for index, line in enumerate(text):
        if (match := KILLED.search(line)) and "process didn't exit successfully" in line:
            signal = signal or match.group(2)
            for earlier in reversed(text[max(0, index - 4):index]):
                if (unit := KILLED_UNIT.match(earlier.strip())) and (name := f"{unit.group(1)} ({unit.group(2)})") not in units:
                    units.append(name)
                    break
    return [signal, *units] if signal else []


# `cargo clippy --fix` runs rustc through cargo itself, so no unit the lint run built is fresh for it: it
# rebuilt every unit of the selection (23m34s in job 141020758253, after a 15.5-min lint run). The steps after
# this one (panic ratchet, frame work contracts, the R2 save) need their time too.
AUTOFIX_COST = 1.5
AUTOFIX_RESERVE_S = 10 * 60


def autofix_fits(lint_seconds: float, now: float | None = None) -> bool:
    """Whether the autofix's rebuild (AUTOFIX_COST times the lint run) still ends AUTOFIX_RESERVE_S before the
    job's cap: CLIPPY_JOB_STARTED (epoch seconds, the workflow's "Start the time budget" step) plus
    CLIPPY_JOB_MINUTES. Without them (a local run) it always fits."""
    try:
        started = int(os.environ["CLIPPY_JOB_STARTED"])
        minutes = int(os.environ["CLIPPY_JOB_MINUTES"])
    except (KeyError, ValueError):
        return True
    left = started + minutes * 60 - (time.time() if now is None else now)
    need = AUTOFIX_COST * lint_seconds + AUTOFIX_RESERVE_S
    if need <= left:
        return True
    print(f"::warning title=cmux-tui clippy::the autofix was not tried: its rebuild needs ~{need / 60:.0f} min "
          f"(the lint run took {lint_seconds / 60:.1f} min) and the job has {max(left, 0) / 60:.0f} min left; "
          f"run `scripts/cmux-next/autofix-clippy.sh` locally or let the PR autofix push it", flush=True)
    return False


def load_isolate(repo: Path):
    """The checkout's scripts/ci/oops/isolate.py (ci-oops fault isolation), or None (an older tree, a replay)."""
    path = repo / "scripts/ci/oops/isolate.py"
    if not path.is_file():
        return None
    spec = importlib.util.spec_from_file_location("ci_oops_isolate", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def warnings_soft(command: list[str], repo: Path) -> list[str]:
    """COMMAND through scripts/ci/warnings_policy.py when CI_WARNINGS=soft (pull requests: warnings never fail
    their compile; Leo, 2026-11-19), else as written. A replayed tree without the policy runs it as written."""
    policy = repo / "scripts/ci/warnings_policy.py"
    if os.environ.get("CI_WARNINGS", "").strip().lower() == "soft" and policy.is_file():
        return [sys.executable, str(policy), "run", "--", *command]
    return command


def is_autofix_head(repo: Path, head: str) -> bool:
    """Whether the pull request head is a PR autofix commit (its Autofix-Run trailer); unreadable counts as one."""
    try:
        if subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{head}^{{commit}}"],
                          capture_output=True).returncode:
            fmt_changed.git(repo, "fetch", "--no-tags", "--quiet", "--depth=1", "origin", head)
        return "\nAutofix-Run: " in "\n" + fmt_changed.git(repo, "log", "-1", "--format=%B", head)
    except subprocess.CalledProcessError:
        return True


def autofixed(repo: Path, command: list[str], paths: list[str], workspace: dict[str, str], head: str) -> bool:
    """Apply the PR autofix's clippy repair to the pull request's own files and lint again (see --autofixed-ok)."""
    if not re.fullmatch(r"[0-9a-f]{40}", head) or is_autofix_head(repo, head):
        return False
    own = {path for path in paths if path.startswith(f"{ROOT}/") and path.endswith(".rs")}
    names, directories = set(), set()
    for path in own:
        for directory in sorted(workspace, key=len, reverse=True):
            if path.startswith(f"{directory}/"):
                names.add(workspace[directory])
                directories.add(directory)
                break
    if not names:
        return False
    packages = [arg for name in sorted(names) for arg in ("-p", name)]
    print("cmux-tui-clippy-changed: red; applying the PR autofix's clippy repair to this change's own files",
          flush=True)
    cwd = repo / ROOT
    try:
        subprocess.run(["cargo", "clippy", "--fix", "--allow-dirty", "--allow-staged", "--locked", "--all-targets",
                        *packages], cwd=cwd, check=True, stdout=subprocess.DEVNULL)
        extra = [path for directory in sorted(directories) for path in fmt_changed.it_test_files(repo, directory)]
        subprocess.run(["cargo", "fmt", *packages, *(["--", *extra] if extra else [])], cwd=cwd, check=True)
    except subprocess.CalledProcessError:
        fmt_changed.git(repo, "checkout", "--quiet", "--", ROOT)
        return False
    edited = [path for path in fmt_changed.git(repo, "diff", "--name-only", "-z", "--", ROOT).split("\0") if path]
    if outside := [path for path in edited if path not in paths]:
        fmt_changed.git(repo, "checkout", "--quiet", "--", *outside)  # the push leaves these (pr-autofix-apply.sh)
    fixed = [path for path in edited if path in paths]
    rc = run_clippy(command, cwd, repo)[0] if fixed else 1
    fmt_changed.git(repo, "checkout", "--quiet", "--", ROOT)
    if rc:
        print("cmux-tui-clippy-changed: the PR autofix's repair leaves lints; they are this change's to fix")
        return False
    print(f"::notice title=cmux-tui clippy (autofixed)::clippy was red only on machine-applicable lints in "
          f"{', '.join(fixed)}; the PR autofix pushes the fix as its own commit, linted strictly there")
    return True


class ClippyRun(NamedTuple):
    rc: int
    red_files: list[str]  # the files compile errors point at (relative to cmux-tui), in order
    lock: str | None  # the lockfile cargo refused to update under --locked
    lints: list[dict]  # each lint diagnostic once: code, level, file, line, column, message
    compile_errors: int  # error diagnostics that are not lints (an E code or none), summaries aside
    lint_errors: int  # error diagnostics that are lints (a level --cap-lints did not reach)


def run_clippy(command: list[str], cwd: Path, repo: Path, text: list[str] | None = None,
               hidden: frozenset[str] = frozenset()) -> ClippyRun:
    """Run clippy (`--message-format=json`) with each diagnostic's rendered text and cargo's own lines
    passed to stderr as they come, and sort what it said into lints and compile errors. TEXT, when given,
    collects every raw line (ci-oops fault isolation reads cargo's `could not compile` lines from it).
    A warning whose code is in HIDDEN (the ratchet's lints, which the run turns on only to share the ratchet's
    fingerprint) is neither printed nor counted; the ratchet judges those."""
    files: list[str] = []
    lints: list[dict] = []
    seen: set[tuple] = set()
    lock = None
    compile_errors = lint_errors = 0
    process = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, errors="replace")
    assert process.stdout is not None
    for line in process.stdout:
        if text is not None:
            text.append(line)
        item = None
        if line.startswith("{"):
            try:
                item = json.loads(line)
            except ValueError:
                item = None
        if not isinstance(item, dict):
            sys.stderr.write(line)
            if (path := red_file(line)) and path not in files:
                files.append(path)
            lock = lock or stale_lock(line, repo)
            # cargo's own errors (a build script that failed, a linker error): never a lint, so never excused.
            if CARGO_ERROR.match(line) and not ERROR_SUMMARY.match(line[len("error: "):]):
                compile_errors += 1
            continue
        if item.get("reason") != "compiler-message":
            continue
        message = item.get("message") or {}
        level = message.get("level") or ""
        code = (message.get("code") or {}).get("code") or ""
        if code in hidden and level == "warning":
            continue
        if rendered := message.get("rendered"):
            sys.stderr.write(rendered if rendered.endswith("\n") else rendered + "\n")
        span = next((s for s in message.get("spans") or [] if s.get("is_primary")), None)
        is_lint = bool(code) and not COMPILE_ERROR_CODE.match(code)
        if level.startswith("error"):
            if is_lint:
                lint_errors += 1
            elif span is not None or not ERROR_SUMMARY.match(message.get("message") or ""):
                compile_errors += 1
                if span is not None and (path := span.get("file_name")) and path not in files:
                    files.append(path)
        if is_lint and span is not None:
            lint = {"code": code, "level": level, "file": span.get("file_name") or "?",
                    "line": span.get("line_start") or 1, "column": span.get("column_start") or 1,
                    "message": message.get("message") or ""}
            key = (lint["code"], lint["file"], lint["line"], lint["column"], lint["message"])
            if key not in seen:
                seen.add(key)
                lints.append(lint)
    sys.stderr.flush()
    return ClippyRun(process.wait(), files, lock, lints, compile_errors, lint_errors)


def escape_data(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def escape_property(text: str) -> str:
    return escape_data(text).replace(":", "%3A").replace(",", "%2C")


def report_lints(lints: list[dict], scope: str) -> None:
    """Each lint as a `::warning file=` annotation (the first MAX_ANNOTATIONS) and a step-summary list.
    A lint never fails the check; it is reported here and fixed forward."""
    if not lints:
        return
    for lint in lints[:MAX_ANNOTATIONS]:
        path = f"{ROOT}/{lint['file']}" if not lint["file"].startswith("/") else lint["file"]
        print(f"::warning file={escape_property(path)},line={lint['line']},col={lint['column']},"
              f"title={escape_property('clippy ' + lint['code'])}::{escape_data(lint['message'])}")
    print(f"cmux-tui-clippy-changed: {len(lints)} lint(s) in {scope}, reported as warnings (lints never fail this check)")
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    rows = [f"- `{ROOT}/{lint['file']}:{lint['line']}` {lint['code']}: {lint['message']}".replace("\n", " ")
            for lint in lints[:200]]
    more = f"\n- ... and {len(lints) - 200} more (the job log has them all)" if len(lints) > 200 else ""
    with open(summary_path, "a", encoding="utf-8") as handle:
        handle.write(f"### clippy: {len(lints)} lint(s), not blocking\n\nLints never fail this check; fix them "
                     f"forward (`cargo clippy --fix` in cmux-tui).\n\n" + "\n".join(rows) + more + "\n")


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
        if verdict := os.environ.get("CMUX_CLIPPY_BASE_RED_FILE"):
            Path(verdict).write_text("base red\n", encoding="utf-8")


VERDICT_VERSION = 1


def tree_oids(repo: Path, rev: str, paths: list[str]) -> dict[str, str]:
    """Each path's blob or tree id at REV (a path REV lacks is left out), from one `git ls-tree`."""
    out = fmt_changed.git(repo, "ls-tree", "-z", "--full-tree", rev, "--", *paths)
    oids = {}
    for entry in out.split("\0"):
        if "\t" in entry:
            meta, path = entry.split("\t", 1)
            oids[path] = meta.split()[2]
    return oids


def package_inputs(package: str, workspace: dict[str, str], requires: dict[str, set[str]]) -> list[str]:
    """What one member's clippy result rests on: its directory, its path dependencies' directories (through any
    member), the workspace manifest and lockfile, and the workspace-wide inputs (EVERY_MEMBER)."""
    by_name = {name: path for path, name in workspace.items()}
    dirs, seen, queue = {by_name[package]}, {package}, deque([package])
    while queue:
        for path in requires.get(queue.popleft(), ()):
            dirs.add(path)
            if (name := workspace.get(path)) and name not in seen:
                seen.add(name)
                queue.append(name)
    return sorted(dirs | {MANIFEST, LOCKFILE} | EVERY_MEMBER)


def owner_of(path: str, workspace: dict[str, str], others: set[str]) -> tuple[str, str] | None:
    """The member owning PATH (relative to cmux-tui, as cargo names it) and PATH relative to the member, or None
    for a file of no member: outside them, or in a path dependency that is not one (OTHERS, such as vendor/)."""
    full = f"{ROOT}/{path}"
    for where in sorted(set(workspace) | others, key=len, reverse=True):
        if full.startswith(where + "/"):
            return (workspace[where], full[len(where) + 1:]) if where in workspace else None
    return None


def write_verdict(repo: Path, out: Path, result: ClippyRun, workspace: dict[str, str],
                  requires: dict[str, set[str]]) -> None:
    """Record the whole-workspace run's verdict for the commit it linted (cmux-tui-clippy-seed.yml saves it), so a
    pull request on this base can leave out a member the base already fails to compile (trusted_base_reds()).
    Each red member keeps the ids of everything its result rests on (package_inputs()): a later base with the same
    ids has the same red. A red file no member owns, a compile error with no file, or a stale lock is no verdict
    (`complete: false`), and nothing is ever left out on it."""
    red: dict[str, dict] = {}
    complete = not result.lock
    others = {path for paths in requires.values() for path in paths} - set(workspace)
    if result.rc and result.compile_errors:
        if not result.red_files:
            complete = False
        for path in result.red_files:
            owner = owner_of(path, workspace, others)
            if owner is None:
                complete = False
                continue
            name, inside = owner
            row = red.setdefault(name, {"files": [], "lib": False})
            row["files"].append(f"{ROOT}/{path}")
            # A library source or build script that fails takes every member using it down with it.
            if inside == "build.rs" or (inside.startswith("src/") and inside != "src/main.rs"
                                        and not inside.startswith("src/bin/")):
                row["lib"] = True
    head = fmt_changed.git(repo, "rev-parse", "HEAD").strip()
    if complete:
        for name, row in red.items():
            inputs = package_inputs(name, workspace, requires)
            oids = tree_oids(repo, head, inputs)
            row["inputs"] = {path: oids.get(path) for path in inputs}
    doc = {"version": VERDICT_VERSION, "sha": head, "complete": complete, "red": red if complete else {}}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    print(f"cmux-tui-clippy-changed: verdict for {head[:12]} written to {out}: "
          + (f"red in {', '.join(sorted(red))}" if red else "green" if complete else "no verdict (unattributed red)"))


def trusted_base_reds(repo: Path, base: str, workspace: dict[str, str]) -> tuple[dict[str, dict], str]:
    """The members the base fails to compile, from the recorded verdict at $CMUX_CLIPPY_BASE_VERDICT (write_verdict(),
    for the base or an earlier feat-cmux-next commit), and that verdict's commit. A member counts only when every
    input its recorded result rests on has the same id at the base, so an older commit's verdict holds exactly
    where nothing it depends on changed since. A missing, unreadable or incomplete verdict trusts none."""
    where = os.environ.get("CMUX_CLIPPY_BASE_VERDICT", "")
    if not where or not base or set(base) == {"0"}:
        return {}, ""
    try:
        doc = json.loads(Path(where).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}, ""
    if not isinstance(doc, dict) or doc.get("version") != VERDICT_VERSION or doc.get("complete") is not True:
        return {}, ""
    sha = str(doc.get("sha") or "")
    members = set(workspace.values())
    trusted: dict[str, dict] = {}
    for name, row in (doc.get("red") or {}).items():
        inputs = row.get("inputs") if isinstance(row, dict) else None
        if name not in members or not isinstance(inputs, dict) or not inputs:
            continue
        try:
            now = tree_oids(repo, base, sorted(inputs))
        except subprocess.CalledProcessError:
            continue
        if all(now.get(path) == oid for path, oid in inputs.items()):
            trusted[name] = row
        else:
            print(f"cmux-tui-clippy-changed: the verdict at {sha[:12]} has {name} red, but its inputs changed "
                  f"before the base {base[:12]}; linting it", flush=True)
    return trusted, sha


def base_red_skips(selected: list[str], changed: set[str], reds: dict[str, dict],
                   dependents: dict[str, set[str]]) -> list[str]:
    """The selected members this change does not touch that the base already fails to compile: a recorded red
    member, or a user of a recorded red member's library. A member the change touches is always linted."""
    roots = {name for name in reds if name not in changed}
    down = set(roots) | with_dependents({name for name in roots if reds[name].get("lib")}, dependents)
    return sorted((set(selected) - changed) & down)


def report_base_red_skips(skipped: list[str], reds: dict[str, dict], dependents: dict[str, set[str]],
                          base: str, sha: str, scope: str, passed: bool | None) -> None:
    """The base-red notice for the members left out, then the verdict on the members this change reaches."""
    left = set(skipped)
    for name in sorted(reds):
        reached = name in left or bool(left & with_dependents({name}, dependents))
        if not reached:
            continue
        for path in reds[name].get("files", []):
            print(f"::warning title=cmux-tui clippy (base red)::{path} is red and this change does not touch it: "
                  f"the base {base[:12]} already fails here (recorded at {sha[:12]}), so this check did not lint "
                  f"{', '.join(skipped)}. Fix it on the base branch in its own pull request")
    if passed is None:
        return
    print(f"cmux-tui-clippy-changed: verdict for the members this change reaches ({scope or 'none'}): "
          f"{'pass' if passed else 'FAIL'}; not linted (red on the base): {', '.join(skipped)}", flush=True)


RED_CRATE = re.compile(r"^  ([A-Za-z0-9_.-]+): clippy::[a-z_]+ [0-9]+ > ")


def still_red(ratchet_out: str, packages: list[str], libs: set[str] | None) -> tuple[list[str], bool] | None:
    """The `-p` arguments and lib flag for the crates the ratchet's --untouched-is-base pass still names red, or
    None (lint every selected package at the base, as before) when it names none, names a crate the run did not
    select, or the caller did not say which packages have a library."""
    if libs is None:
        return None
    crates = sorted({m.group(1) for line in ratchet_out.splitlines() if (m := RED_CRATE.match(line))})
    if not crates:
        return None
    selected = set(packages[1::2]) if packages and packages[0] == "-p" else None
    if selected is not None and not set(crates) <= selected:
        return None
    return [arg for crate in crates for arg in ("-p", crate)], any(crate in libs for crate in crates)


def artifact_package(package_id: str) -> str:
    """The package name in a cargo JSON `package_id`: `name 1.0 (path+file://...)` on older cargo,
    `path+file:///.../dir#1.0` or `path+file:///.../dir#name@1.0` on newer."""
    if not package_id.startswith(("path+", "registry+", "git+", "sparse+")):
        return package_id.split(" ", 1)[0]
    location, _, fragment = package_id.rpartition("#")
    if "@" in fragment:
        return fragment.split("@", 1)[0]
    return location.rstrip("/").rsplit("/", 1)[-1]


def head_features(clippy_json: Path, crates: list[str]) -> list[str] | None:
    """`--no-default-features --features ...` that give each of `crates` the features cargo unified for it in the
    head run, or None when the run names no artifact for one of them. Linting a crate alone resolves only its own
    defaults: cmux#45686 (2026-11-28) linted acpmux with cmux-tui (hub-carrier) and cmux-tui-core (test-support),
    then linted the base with `-p acpmux` alone, so the base counted fewer hits (indexing_slicing 788 vs the head's
    870) and the hits a dependent's features compile read as the change's."""
    found: dict[str, set[str]] = {}
    try:
        lines = clippy_json.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None
    for line in lines:
        if '"compiler-artifact"' not in line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        name = artifact_package(str(message.get("package_id", "")))
        if name in crates:
            found.setdefault(name, set()).update(message.get("features") or [])
    if set(crates) - set(found):
        return None
    wanted = sorted(f"{crate}/{feature}" for crate in crates for feature in found[crate])
    return ["--no-default-features", *(["--features", ",".join(wanted)] if wanted else [])]


def ratchet_targets(has_lib):
    """The panic ratchet's cargo targets: production code, plus examples so cargo unifies features as --all-targets did
    (see the module docstring); the ratchet skips example messages."""
    return ["--lib", "--bins", "--examples"] if has_lib else ["--bins", "--examples"]


def panic_ratchet(repo: Path, packages: list[str], has_lib: bool, scope: str, out: Path, compare: str = "",
                  libs: set[str] | None = None) -> int:
    """Lint the production targets of `packages` with the ratchet's flags into `out`, then let
    the ratchet judge them. Cargo refuses `--lib` when no selected package has a library.
    With `compare` (a base commit) a HEAD the baseline already passes is green as it stands:
    the base run only excuses counts over the baseline, so it cannot change that verdict. Only
    a red HEAD lints the base too, into `<out>.base`, and the ratchet then charges HEAD only for
    counts the base does not reach. On a green PR that skips one lint of the changed packages
    (80 s of the job's 6 min on #37445, run 42334950081).
    An optional member the clippy step before it left out (ci-oops, CMUX_OOPS_DROPPED_CARGO_MEMBER) is left out here
    too: it does not compile, and the ratchet keeps its baseline row."""
    if (oops := load_isolate(repo)) and (gone := oops.dropped_from_env("cargo-member")):
        print(f"cmux-tui-clippy-changed: leaving out {', '.join(gone)} (ci-oops: it does not compile on this pull "
              "request; the clippy step filed its follow-up)", flush=True)
        packages = oops.without("cargo-member", packages, gone)
        if packages is None:
            print("cmux-tui-clippy-changed: no package left for the panic ratchet", flush=True)
            return 0
    ratchet = repo / RATCHET
    flags = subprocess.run([sys.executable, str(ratchet), "--flags"], check=True,
                           stdout=subprocess.PIPE, text=True).stdout.split()
    targets = ratchet_targets(has_lib)
    command = ["cargo", "clippy", "--locked", *packages, *targets, "--message-format=json", "--", *flags, *CAP_LINTS]
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
        # A count over the baseline with every hit in a file this change never touched is the base's own drift
        # (a crate that merged over its row, or with none): the base run could only excuse it. Linting the base
        # cost ~5 min a job (run 45929462416: 20 crates over, none touched); only a hit in a touched file needs it.
        untouched = subprocess.run([*judge, "--untouched-is-base", "--diff-base", compare],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if untouched.returncode == 0:
            print(untouched.stdout, end="", flush=True)
            print(f"cmux-tui-clippy-changed: every count over the baseline is in files this change does not touch, "
                  f"so the base {compare} is not linted", flush=True)
            return 0
        base_out = out.with_name(out.name + ".base")
        head = fmt_changed.git(repo, "rev-parse", "HEAD").strip()
        # Only the crates still red after the untouched pass read the base run, so the base lints just those
        # (their dependents are never judged against it). Before, it linted every selected package again:
        # 1.5-2.8 min in 9 of 40 sampled clippy-changed steps (2026-11-27), mostly dependents such as cmux-tui
        # that a change to acpmux reaches but whose counts the base run never excused. The final judge keeps
        # --untouched-is-base, so a crate the base run now leaves out is judged as the untouched pass judged it.
        base_command = command
        base_scope = scope
        red = still_red(untouched.stdout, packages, libs)
        # The narrowed lint keeps the head run's unified features, else it lints every selected package as before.
        features = head_features(out, red[0][1::2]) if red is not None else None
        if red is not None and features is not None:
            red_packages, red_has_lib = red
            targets = ratchet_targets(red_has_lib)
            base_command = ["cargo", "clippy", "--locked", *red_packages, *features, *targets,
                            "--message-format=json", "--", *flags, *CAP_LINTS]
            base_scope = ", ".join(red_packages[1::2])
            judge += ["--untouched-is-base", "--diff-base", compare]
        print(f"cmux-tui-clippy-changed: HEAD is over the baseline; panic ratchet on {base_scope} at the base {compare}",
              flush=True)
        print(" ".join(base_command), flush=True)
        fmt_changed.git(repo, "checkout", "--quiet", "--detach", compare)
        try:
            with base_out.open("w", encoding="utf-8") as handle:
                subprocess.run(base_command, cwd=repo / ROOT, stdout=handle)
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
