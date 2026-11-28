#!/usr/bin/env python3
"""Compile only the patch's files: inject.sh's fast path.

    patch_compile.py --plan PLAN --work DIR NAME...

PLAN is the driver's `swiftc -c <every module file> FLAGS -###` output, which inject.sh keeps per toolchain, flags
and file list. This runs only the frontend jobs whose primary file is one of NAME (each of the module's other files
read as a secondary, exactly as the full compile does) and writes DIR/NAME.o for each. The full compile ran every
file's job and the driver around them, though only the patched files' objects are linked: 745 ms where the one job
takes 84 (goal dev-loop-ceiling, swift_inject on a fleet Mac, step 47d6fad6641ac4fe909234ea).

    patch_compile.py --link-plan PLAN --work DIR --out ARGV

The link's kept plan: PLAN is `swiftc -emit-library DIR/NAME.o... -o DIR/patch.dylib FLAGS -###`. When it is one
linker job, ARGV gets that job's arguments NUL-separated, DIR written as @WORK@, so inject.sh runs it from bash for
any later patch of the same files (no driver, no python). Exit 3 when the plan is anything else.

Exit 0: every NAME.o written. Exit 3: the plan has no job for a NAME, or it cannot be read; inject.sh then runs the
full compile. A job that fails exits with its code and prints its diagnostics."""
import argparse
import os
import shlex
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor


def jobs(path):
    out = []
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith(("warning:", "note:")):
                continue
            try:
                argv = shlex.split(line)
            except ValueError:
                continue
            if "-frontend" in argv and "-c" in argv:
                out.append(argv)
    return out


def primaries_and_outputs(argv):
    """[(primary file, its -o path)] in order: the frontend pairs the n-th -primary-file with the n-th -o."""
    primaries = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "-primary-file"]
    outputs = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "-o"]
    return list(zip(primaries, outputs)) if len(primaries) == len(outputs) else []


def make_parents(argv):
    # A -### plan names the driver's temporary folders, which only a real run makes. Only output-like paths: not a
    # plugin spec (DIR#Module) and nothing inside an .app (Xcode is read-only).
    for arg in argv[1:]:
        parent = os.path.dirname(arg)
        if not os.path.isabs(arg) or "#" in arg or ".app/Contents/" in arg or os.path.exists(parent):
            continue
        try:
            os.makedirs(parent, exist_ok=True)
        except OSError:
            pass


def link_plan(plan, work, out):
    """One linker job from a `-emit-library -###` plan, kept as NUL-separated argv with WORK as @WORK@."""
    try:
        lines = [l.strip() for l in open(plan) if l.strip() and not l.lstrip().startswith(("warning:", "note:"))]
        argvs = [shlex.split(l) for l in lines]
    except (OSError, ValueError):
        return 3
    if len(argvs) != 1:
        return 3
    argv = argvs[0]
    tool = os.path.basename(argv[0])
    if not os.path.isabs(argv[0]) or tool not in ("ld", "ld64", "ld-prime", "clang"):
        return 3
    roots = sorted({work.rstrip("/"), os.path.realpath(work)}, key=len, reverse=True)
    if not any(a == os.path.join(r, "patch.dylib") for a in argv for r in roots):
        return 3

    def portable(arg):
        for root in roots:
            arg = arg.replace(root + "/", "@WORK@/")
        return arg

    kept = [portable(a) for a in argv]
    if any("\0" in a for a in kept):
        return 3
    with open(out, "wb") as handle:
        handle.write(b"".join(a.encode() + b"\0" for a in kept))
    return 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--plan")
    p.add_argument("--link-plan")
    p.add_argument("--out")
    p.add_argument("--work", required=True)
    p.add_argument("names", nargs="*")
    a = p.parse_args()
    if a.link_plan:
        if not a.out:
            p.error("--link-plan needs --out")
        return link_plan(a.link_plan, a.work, a.out)
    if not a.plan or not a.names:
        p.error("--plan and at least one NAME")
    try:
        plan = jobs(a.plan)
    except OSError:
        return 3
    wanted = set(a.names)
    run = []  # (argv, [(name, output)])
    found = set()
    for argv in plan:
        mine = [(os.path.basename(f)[: -len(".swift")], o) for f, o in primaries_and_outputs(argv)
                if f.endswith(".swift") and os.path.basename(f)[: -len(".swift")] in wanted]
        if mine:
            run.append((argv, mine))
            found.update(n for n, _ in mine)
    if found != wanted:
        return 3
    for argv, mine in run:
        # Each primary's object goes straight to DIR/NAME.o: the plan's own temporary names are the same on every
        # run of a cached plan, so two patches at once would share them.
        names = [os.path.basename(f)[: -len(".swift")] for f, _ in primaries_and_outputs(argv)]
        index = 0
        for i in range(len(argv) - 1):
            if argv[i] == "-o":
                argv[i + 1] = os.path.join(a.work, f"{names[index]}.o")
                index += 1
        make_parents(argv)

    def one(item):
        argv, _ = item
        return subprocess.run(argv, cwd=a.work, capture_output=True, text=True)

    with ThreadPoolExecutor(max_workers=max(1, len(run))) as pool:
        results = list(pool.map(one, run))
    for (argv, mine), done in zip(run, results):
        if done.returncode:
            sys.stderr.write(done.stderr)
            return done.returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
