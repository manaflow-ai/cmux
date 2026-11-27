#!/usr/bin/env python3
"""Pick the iOS flows a change can affect, from flows.json.

  select_flows.py --changed-files FILE        one repo-relative path per line
  select_flows.py --base SHA --head SHA       git diff --name-only BASE...HEAD
  select_flows.py PATH [PATH ...]

Prints {"ios": bool, "compile": bool, "flows": [...], "kit": [...], "ui": [...],
"swift": [...], "scripts": [...], "build_for_testing": bool, "reason": {...}}.
--sim-args prints the scripts/ci/cmux-next-ios-sim.sh arguments instead
(`test only=A,B ui=C,D`), one line per shard with --shards N.
--print-compile-paths prints the globs that make a change iOS-affecting.
--check validates the manifest against the tree (every suite exists, every
regression row has a flow) and exits non-zero on a problem.

Rules (README.md): a change is iOS-affecting iff a changed file, after
compile.ignore, matches a compile glob (compile.paths plus the Swift packages
and Rust crates the app links, derived from compile.swift_roots and
compile.cargo_roots, plus with compile.ffi_closure every crate
CmuxMobileLinkFFI compiles, read from its Cargo graph by
scripts/ci/ios_link_ffi_key.py) or any flow's paths. Selected = smoke flows + flows whose
paths match + build_for_testing flows when compile matched.
"""
from __future__ import annotations

import argparse
import functools
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
MANIFEST = HERE / "flows.json"
REGRESSION_ROWS = 20


@functools.lru_cache(maxsize=None)
def glob_re(pattern: str) -> re.Pattern[str]:
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def matches(path: str, patterns: list[str]) -> list[str]:
    return [p for p in patterns if glob_re(p).match(path)]


def rel(p: Path, root: Path) -> str | None:
    try:
        return p.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return None


SWIFT_DEP = re.compile(r'\.package\(\s*path:\s*"([^"]+)"')
YML_PATH = re.compile(r"^\s+path:\s*(\S+)\s*$", re.M)
CARGO_DEP = re.compile(r'path\s*=\s*"([^"]+)"')


def swift_closure(roots: list[str], root: Path) -> set[str]:
    """Package directories reachable from project.yml / Package.swift roots."""
    seen: set[str] = set()
    todo: list[Path] = []
    for r in roots:
        f = root / r
        if not f.is_file():
            continue
        text = f.read_text()
        deps = YML_PATH.findall(text) if f.suffix == ".yml" else SWIFT_DEP.findall(text)
        if f.name == "Package.swift":
            todo.append(f.parent)
        todo += [(f.parent / d) for d in deps]
    while todo:
        d = todo.pop()
        r = rel(d, root)
        if r is None or r in seen or not (d / "Package.swift").is_file():
            continue
        seen.add(r)
        todo += [d / x for x in SWIFT_DEP.findall((d / "Package.swift").read_text())]
    return seen


def cargo_closure(roots: list[str], root: Path) -> set[str]:
    """Crate directories reachable by path dependencies from Cargo.toml roots."""
    seen: set[str] = set()
    todo: list[Path] = []
    for r in roots:
        f = root / r
        if not f.is_file():
            continue
        todo.append(f.parent)
        todo += [m.parent for m in f.parent.glob("crates/*/Cargo.toml")]
    while todo:
        d = todo.pop()
        r = rel(d, root)
        if r is None or r in seen or not (d / "Cargo.toml").is_file():
            continue
        seen.add(r)
        todo += [d / x for x in CARGO_DEP.findall((d / "Cargo.toml").read_text()) if x != "."]
    return seen


@functools.lru_cache(maxsize=None)
def ffi_closure(root: Path) -> tuple[list[str], list[str]]:
    """(every crate directory CmuxMobileLinkFFI compiles, the workspace roots they sit in), from the Cargo
    graph at ROOT's HEAD: scripts/ci/ios_link_ffi_key.py's `closure`, the walk that keys the xcframework
    cache, so the gate and the cache can never name different crates. ([], []) outside a git checkout."""
    sys.path.insert(0, str(root / "scripts/ci"))
    try:
        import ios_link_ffi_key as key
    except ImportError:
        return [], []
    finally:
        sys.path.pop(0)
    if key.tomllib is None or not (root / ".git").exists() or not (root / key.FFI / "Cargo.toml").is_file():
        return [], []
    here = os.getcwd()
    os.chdir(root)  # the walk reads git objects from the current directory's repository
    try:
        return key.closure("HEAD")
    finally:
        os.chdir(here)


def compile_globs(manifest: dict, root: Path) -> list[str]:
    c = manifest.get("compile", {})
    globs = list(c.get("paths", []))
    crates, roots = ffi_closure(root) if c.get("ffi_closure") else ([], [])
    derived = swift_closure(c.get("swift_roots", []), root) | cargo_closure(c.get("cargo_roots", []), root) | set(crates)
    for d in sorted(derived):
        g = f"{d}/**"
        if not matches(f"{d}/x", globs):
            globs.append(g)
    for r in roots:  # a workspace root's manifest and lock, not its other members
        for name in ("Cargo.toml", "Cargo.lock"):
            g = f"{r}/{name}" if r not in ("", ".") else name
            if not matches(g, globs):
                globs.append(g)
    return globs


def select(manifest: dict, changed: list[str], root: Path = REPO) -> dict:
    ignore = manifest.get("compile", {}).get("ignore", [])
    files = [f for f in changed if f and not matches(f, ignore)]
    cglobs = compile_globs(manifest, root)
    compile_hits = [f for f in files if matches(f, cglobs)]
    reason: dict[str, list[str]] = {}
    chosen = []
    for flow in manifest["flows"]:
        hits = [f for f in files if matches(f, flow.get("paths", []))]
        if hits:
            reason[flow["id"]] = hits
            chosen.append(flow)
    ios = bool(compile_hits or chosen)
    if compile_hits:
        reason["compile"] = compile_hits
    selected = []
    if ios:
        for flow in manifest["flows"]:
            if flow.get("smoke") or flow in chosen or (compile_hits and flow.get("build_for_testing")):
                selected.append(flow)

    def union(key: str) -> list:
        out: list = []
        for f in selected:
            value = f.get(key, [])
            if isinstance(value, bool):  # "pair_e2e": true asks for the run with no extra words
                continue
            for x in value:
                if x not in out:
                    out.append(x)
        return out

    scripts = union("scripts")
    if compile_hits:
        scripts = manifest.get("compile", {}).get("scripts", []) + [s for s in scripts if s not in manifest["compile"].get("scripts", [])]
    return {
        "ios": ios,
        "compile": bool(compile_hits),
        "build_for_testing": any(f.get("build_for_testing") for f in selected),
        "flows": [f["id"] for f in selected],
        "kit": union("kit"),
        "ui": union("ui"),
        "swift": union("swift"),
        "scripts": scripts,
        "pair_e2e": union("pair_e2e"),
        "pair": any(f.get("pair_e2e") for f in selected),
        "reason": reason,
    }


def sim_args(result: dict, shards: int) -> list[str]:
    if not result["ios"]:
        return []
    shards = max(1, shards)
    kit = [result["kit"][i::shards] for i in range(shards)]
    ui = [result["ui"][i::shards] for i in range(shards)]
    lines = []
    for k, u in zip(kit, ui):
        parts = ["test"]
        if k:
            parts.append("only=" + ",".join(k))
        if u:
            parts.append("ui=" + ",".join(u))
        if k or u:
            lines.append(" ".join(parts))
    if result.get("pair") or result.get("pair_e2e"):  # a paired Mac and iPhone: its own run (cmux-next-ios-sim.sh pair-e2e WORD...)
        lines.append(" ".join(["pair-e2e", *result["pair_e2e"]]))
    return lines or ["build"]


def check(manifest: dict, root: Path = REPO) -> list[str]:
    problems = []
    ids = [f["id"] for f in manifest["flows"]]
    if len(ids) != len(set(ids)):
        problems.append("duplicate flow ids")
    rows = {s for f in manifest["flows"] for s in f.get("source", []) if s.startswith("regression:")}
    for n in range(1, REGRESSION_ROWS + 1):
        if f"regression:{n}" not in rows:
            problems.append(f"regression row {n} has no flow")
    if manifest.get("compile", {}).get("ffi_closure") and (root / ".git").exists() and not ffi_closure(root)[0]:
        problems.append("compile.ffi_closure: the CmuxMobileLinkFFI Cargo graph could not be read")
    ui_dir = root / "cmux-next-ios/UITests"
    kit_dir = root / "cmux-next-ios/CmuxMobileKit/Tests"
    for f in manifest["flows"]:
        fid = f["id"]
        for suite in f.get("ui", []):
            hit = any(re.search(rf"\bclass {re.escape(suite)}\b", p.read_text(errors="ignore"))
                      for p in ui_dir.glob("*.swift"))
            if not hit:
                problems.append(f"{fid}: UI suite {suite} not found in cmux-next-ios/UITests")
        for t in f.get("kit", []):
            target, _, suite = t.partition("/")
            d = kit_dir / target
            if not d.is_dir():
                problems.append(f"{fid}: kit target {target} not found")
                continue
            if suite and not any(re.search(rf"\b(class|struct) {re.escape(suite)}\b", p.read_text(errors="ignore"))
                                 for p in d.rglob("*.swift")):
                problems.append(f"{fid}: kit suite {t} not found")
        for s in f.get("swift", []):
            pkg = root / s["package"]
            if not (pkg / "Package.swift").is_file():
                problems.append(f"{fid}: package {s['package']} not found")
            elif not any(re.search(rf"\b(class|struct) {re.escape(s['filter'])}\b", p.read_text(errors="ignore"))
                         for p in (pkg / "Tests").rglob("*.swift")):
                problems.append(f"{fid}: {s['filter']} not found in {s['package']}/Tests")
        for p in f.get("paths", []):
            base = p.split("*", 1)[0].rstrip("/")
            if base and not (root / base).exists():
                problems.append(f"{fid}: path {p} matches nothing in the tree")
        if not (f.get("kit") or f.get("ui") or f.get("swift") or f.get("scripts") or f.get("pair_e2e")
                or f.get("build_for_testing")):
            problems.append(f"{fid}: no check")
    return problems


def changed_from_git(base: str, head: str) -> list[str]:
    out = subprocess.run(["git", "-C", str(REPO), "diff", "--name-only", f"{base}...{head}"],
                         check=True, capture_output=True, text=True).stdout
    return out.splitlines()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--changed-files")
    ap.add_argument("--base")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--manifest", default=str(MANIFEST))
    ap.add_argument("--sim-args", action="store_true")
    ap.add_argument("--shards", type=int, default=1)
    ap.add_argument("--print-compile-paths", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    manifest = json.loads(Path(a.manifest).read_text())
    if a.check:
        problems = check(manifest)
        for p in problems:
            print(p, file=sys.stderr)
        print(f"{len(manifest['flows'])} flows, {len(problems)} problems")
        return 1 if problems else 0
    if a.print_compile_paths:
        print("\n".join(compile_globs(manifest, REPO)))
        return 0
    changed = list(a.paths)
    if a.changed_files:
        changed += Path(a.changed_files).read_text().splitlines()
    if a.base:
        changed += changed_from_git(a.base, a.head)
    result = select(manifest, [c.strip() for c in changed])
    if a.sim_args:
        print("\n".join(sim_args(result, a.shards)))
    else:
        print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
