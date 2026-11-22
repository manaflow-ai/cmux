#!/usr/bin/env python3
"""The main thread of a macOS `sample` file: its total, how much of it is idle, and
its heaviest inclusive frames from the libraries that matter for UI work.

    python3 samplecut.py FILE.sample.txt [--top 30] [--json]
"""
import collections
import json
import re
import sys

LIBS = ("CmuxMobileApp", "QuartzCore", "CoreText", "CoreGraphics", "SwiftUI", "SwiftUICore", "UIKitCore", "AttributeGraph")
IDLE = ("mach_msg2_trap", "__CFRunLoopServiceMachPort")
LINE = re.compile(r"^[\s+!:|]*(\d+)\s+(.+?)\s+\(in ([^)]+)\)")


def main_thread(text):
    # The main thread is the first thread of the call graph ("Main Thread" or
    # "com.apple.main-thread", depending on what it was running when sampled).
    m = re.search(r"^\s{4}\d+ Thread_\S+:? .*(Main Thread|com\.apple\.main-thread).*$", text, re.M)
    if not m:
        return []
    lines = text[m.end():].split("\n")[1:]
    out = []
    for line in lines:
        if re.match(r"^\s{4}\d+ Thread_", line) or line.startswith("Total number in stack"):
            break
        out.append(line)
    return out


def cut(path, top=30):
    text = open(path, errors="replace").read()
    lines = main_thread(text)
    total = 0
    frames = collections.Counter()
    idle = 0
    for line in lines:
        m = LINE.match(line)
        if not m:
            continue
        n, name, lib = int(m.group(1)), m.group(2), m.group(3)
        total = max(total, n)
        if any(name.startswith(i) for i in IDLE):
            idle = max(idle, n) if name.startswith("__CFRunLoopServiceMachPort") else idle
        if lib in LIBS:
            key = f"{lib}: {name[:110]}"
            frames[key] = max(frames[key], n)
    busy = total - idle
    return {"file": path, "main_samples": total, "idle_samples": idle,
            "busy_pct": round(100 * busy / total, 1) if total else None,
            "top": [(v, k) for k, v in frames.most_common(top)]}


if __name__ == "__main__":
    args = sys.argv[1:]
    top = int(args[args.index("--top") + 1]) if "--top" in args else 30
    r = cut(args[0], top)
    if "--json" in args:
        print(json.dumps(r, indent=1))
    else:
        print(f"main thread: {r['main_samples']} samples, busy {r['busy_pct']}%")
        for v, k in r["top"]:
            print(f"{v:6} {k}")
