#!/usr/bin/env python3
"""Codex-like inline TUI, no model (G-17 regression scenarios). Like Codex's working
state, it streams numbered history rows above a live area that it erases and redraws in
place (cursor up, erase below), then idles at its prompt and keeps redrawing the live
area, whose height changes by a row or two (a status line and a hint line come and go,
as Codex's do). This is the mechanism behind D2 and the user's 13:37 video: the
document's end moves as the live area shrinks and grows.

usage: codexlike.py [WORK_S=30] [RATE=10] [IDLE_S=30] [IDLE_HZ=2]
Rows: `#%07d` + diff-like text (rows.py reads the id). Ends with CODEXLIKE-END rows=N.
"""
import sys
import time

if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
    print("usage: codexlike.py [WORK_S=30] [RATE=10] [IDLE_S=30] [IDLE_HZ=2]")
    sys.exit(0)
work_s = float(sys.argv[1]) if len(sys.argv) > 1 else 30
rate = float(sys.argv[2]) if len(sys.argv) > 2 else 10
idle_s = float(sys.argv[3]) if len(sys.argv) > 3 else 30
idle_hz = float(sys.argv[4]) if len(sys.argv) > 4 else 2

out = sys.stdout
live_rows = 0  # rows of the live area above the cursor's row
n = 0
DIFF = ["+    let anchor = TerminalCellPoint(row: row, column: 0)", "-    selection = nil",
        "     guard let surface else { return nil }", "+    // keep the reader's row on screen",
        "@@ -207,12 +207,18 @@ final class TerminalViewController", "     }"]


def live(working, elapsed, hint):
    lines = []
    if working:
        lines.append(f"\x1b[2m•\x1b[0m Working ({int(elapsed)}s • esc to interrupt)")
    lines.append("")
    lines.append("\x1b[2m╭" + "─" * 40 + "╮\x1b[0m")
    lines.append("\x1b[2m│\x1b[0m › Ask Codex to do anything")
    lines.append("\x1b[2m╰" + "─" * 40 + "╯\x1b[0m")
    if hint:
        lines.append("\x1b[2m  ⏎ send   ⇧⏎ newline   ⌃T transcript\x1b[0m")
        lines.append("\x1b[2m  ⌃C quit   ⌃J newline\x1b[0m")
    lines.append("\x1b[2m  100% context left\x1b[0m")
    return lines


def redraw(new_rows, working, elapsed, hint):
    global live_rows
    buf = []
    if live_rows:
        buf.append(f"\x1b[{live_rows}A")
    buf.append("\r\x1b[J")
    for row in new_rows:
        buf.append(row + "\r\n")
    lines = live(working, elapsed, hint)
    buf.append("\r\n".join(lines))
    # Like Codex, the cursor then sits in the prompt box, so the footer rows
    # (which come and go) are below the cursor.
    prompt = next(i for i, l in enumerate(lines) if "Ask Codex" in l)
    below = len(lines) - 1 - prompt
    if below:
        buf.append(f"\x1b[{below}A")
    buf.append("\x1b[31G")
    live_rows = prompt
    out.write("".join(buf))
    out.flush()


t0 = time.time()
next_t = t0
try:
    while time.time() - t0 < work_s:
        rows = []
        due = int((time.time() - t0) * rate) - n
        for _ in range(max(0, due)):
            n += 1
            rows.append(f"#{n:07d} \x1b[3{1 + n % 2}m{DIFF[n % len(DIFF)]}\x1b[0m")
        redraw(rows, True, time.time() - t0, False)
        next_t += 0.1
        time.sleep(max(0, next_t - time.time()))
    t1 = time.time()
    k = 0
    while time.time() - t1 < idle_s:
        k += 1
        # Every other redraw the hint line comes or goes: the live area grows
        # and shrinks by one row while nothing new is printed.
        redraw([], False, 0, k % 2 == 0)
        time.sleep(1 / idle_hz)
finally:
    redraw([], False, 0, False)
    out.write("\x1b[J")
    out.write(f"\r\nCODEXLIKE-END rows={n}\r\n")
    out.flush()
