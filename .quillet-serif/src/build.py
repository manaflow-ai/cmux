#!/usr/bin/env python3
"""Builds the three Quillet faces into fonts/ and prints what each file came to.

Runs sans.py, serif.py and mono.py in turn with --out fonts. Each writes
quillet-<face>.woff2 and quillet-<face>-italic.woff2, plus a build/out/<face>.json report.

    pip install -r build/requirements.txt && python3 build/build.py
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

BUILD = Path(__file__).resolve().parent
ROOT = BUILD.parent
FONTS = ROOT / "fonts"
FACES = ["sans", "serif", "mono"]
# What cmux takes per face file (cmux_config::font_faces::MAX_FACE_BYTES).
MAX_FACE_BYTES = 2 * 1024 * 1024
# What one cmux theme carries in fonts/ (font files and license texts).
MAX_FILES = 8


def main() -> int:
    FONTS.mkdir(exist_ok=True)
    for face in FACES:
        script = BUILD / f"{face}.py"
        print(f"building quillet-{face} ({script.name})", flush=True)
        done = subprocess.run([sys.executable, str(script), "--out", str(FONTS)], cwd=ROOT)
        if done.returncode != 0:
            print(f"{script.name} failed (exit {done.returncode})", file=sys.stderr)
            return done.returncode

    rows = []
    too_big = []
    for face in FACES:
        report = BUILD / "out" / f"{face}.json"
        for name in (f"quillet-{face}.woff2", f"quillet-{face}-italic.woff2"):
            path = FONTS / name
            if not path.is_file():
                print(f"{name}: missing after {face}.py", file=sys.stderr)
                return 1
            size = path.stat().st_size
            if size > MAX_FACE_BYTES:
                too_big.append(name)
            rows.append((name, size, f"build/out/{report.name}" if report.is_file() else "-"))

    width = max(len(name) for name, _, _ in rows)
    print()
    print(f"{'file':<{width}}  {'bytes':>9}  {'KiB':>7}  report")
    for name, size, report in rows:
        print(f"{name:<{width}}  {size:>9}  {size / 1024:>7.1f}  {report}")
    total = sum(size for _, size, _ in rows)
    print(f"{'total':<{width}}  {total:>9}  {total / 1024:>7.1f}")

    if too_big:
        print(f"larger than cmux takes (2 MiB a face): {', '.join(too_big)}", file=sys.stderr)
        return 1
    files = [p for p in FONTS.iterdir() if p.is_file() and not p.name.startswith(".")]
    if len(files) > MAX_FILES:
        print(f"fonts/ has {len(files)} files; a cmux theme carries at most {MAX_FILES}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
