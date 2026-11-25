#!/usr/bin/env python3
"""Compile only the patch's files: inject.sh's fast path.

    patch_compile.py --plan PLAN --work DIR NAME...

PLAN is the driver's `swiftc -c <every module file> FLAGS -###` output, which inject.sh keeps per toolchain, flags
and file list. This runs only the frontend jobs whose primary file is one of NAME (each of the module's other files
read as a secondary, exactly as the full compile does) and writes DIR/NAME.o for each. The full compile ran every
file's job and the driver around them, though only the patched files' objects are linked: 745 ms where the one job
takes 84 (goal dev-loop-ceiling, swift_inject on cmux17, step 47d6fad6641ac4fe909234ea).

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


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--plan", required=True)
    p.add_argument("--work", required=True)
    p.add_argument("names", nargs="+")
    a = p.parse_args()
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
