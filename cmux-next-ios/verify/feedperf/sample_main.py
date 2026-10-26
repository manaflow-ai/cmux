#!/usr/bin/env python3
"""Main-thread hot frames from a macOS `sample` report.

usage: sample_main.py FILE.sample.txt [--match REGEX] [--top N] [--paths REGEX]
Prints the main thread's total samples, then the frames with the most
inclusive samples (a frame counted once per stack), filtered by --match
(default: the app's own modules and SwiftUI/UIKit/WebKit entry points).
--paths REGEX prints, for each matching frame, its heaviest callers chain.
"""
import re
import sys
from collections import Counter

LINE = re.compile(r"^(?P<indent>[ +!:|]*)(?P<count>\d+) (?P<name>.+?)(  \(in (?P<lib>[^)]+)\))?( \+ \d+)?(  \[0x[0-9a-f,]+\])?\s*$")


def main_thread_nodes(path):
    lines = open(path, errors="replace").read().splitlines()
    out, inside = [], False
    for line in lines:
        if not inside:
            if re.match(r"^\s+\d+ Thread_\d+.*(Main Thread|com\.apple\.main-thread)", line):
                inside = True
                base = len(line) - len(line.lstrip(" +!:|"))
            continue
        if not line.strip() or (re.match(r"^\s+\d+ Thread_", line)):
            break
        m = LINE.match(line)
        if not m:
            continue
        depth = len(m.group("indent"))
        name = m.group("name").strip()
        name = re.sub(r"\s+\[0x[0-9a-f,]+\].*$", "", name)
        out.append((depth - base, int(m.group("count")), name, m.group("lib") or ""))
    return out


def main():
    path = sys.argv[1]
    args = sys.argv[2:]
    match = re.compile(args[args.index("--match") + 1]) if "--match" in args else re.compile(r"CmuxMobile|Cmux|Feed|WebMarkdown|Pooled")
    top = int(args[args.index("--top") + 1]) if "--top" in args else 40
    nodes = main_thread_nodes(path)
    if not nodes:
        sys.exit("no main thread found")
    total = nodes[0][1]
    inclusive = Counter()
    stack = []
    for depth, count, name, lib in nodes:
        while stack and stack[-1][0] >= depth:
            stack.pop()
        if not any(s[2] == name for s in stack):
            inclusive[(name, lib)] += count
        stack.append((depth, count, name))
    idle = sum(c for (n, _), c in inclusive.items() if n.startswith("mach_msg2_trap"))
    print(f"main thread samples: {total} (ms at 1 ms), in mach_msg (idle): {idle}, busy ~{total - idle}")
    rows = [(c, n, l) for (n, l), c in inclusive.items() if match.search(n) or match.search(l)]
    for c, n, l in sorted(rows, reverse=True)[:top]:
        print(f"{c:7d}  {n[:150]}  [{l}]")


if __name__ == "__main__":
    main()
