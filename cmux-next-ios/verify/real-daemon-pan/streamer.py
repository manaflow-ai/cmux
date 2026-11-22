#!/usr/bin/env python3
"""A Claude Code-like program for the real-daemon pan bench (RealDaemonPanUITests).

    streamer.py primary ROWS PERIOD_MS DONE_FILE
    streamer.py alt ROWS PERIOD_MS DONE_FILE

Both first print ROWS styled transcript rows (bullets, bold, dim, colors, diff
lines; each numbered `#NNNNN`), then touch DONE_FILE and stream until killed:

- primary: as Claude Code's inline renderer does, every PERIOD_MS a new
  transcript row goes above a 5-row live region (spinner, token count, input
  box), which is erased (`ESC[5F ESC[J`) and redrawn.
- alt: a full-screen app on the alternate screen with the mouse asked for
  (1000 + 1006 SGR). It adds a log row and redraws the whole screen every
  PERIOD_MS; each wheel report (`ESC[<64;..M` up, `ESC[<65;..M` down) moves its
  view and redraws at once, with `WHEEL#N` (wheel reports read so far) in its
  status row, so the phone can time a wheel's round trip.
"""

import os
import select
import sys
import termios
import time
import tty

ESC = "\x1b"
LIVE = 5
SPIN = "✻✽✶✳✢·"


def row(n: int) -> str:
    kind = n % 9
    tag = f"{ESC}[2m#{n:05d}{ESC}[0m "
    if kind == 0:
        return tag + f"{ESC}[1;38;5;174m⏺{ESC}[0m {ESC}[1mUpdate{ESC}[0m(cmux-next-ios/Sources/Terminal{n % 37}.swift)"
    if kind == 1:
        return tag + f"  ⎿  {ESC}[2mUpdated {ESC}[1mTerminal{n % 37}.swift{ESC}[0m{ESC}[2m with {n % 11} additions and {n % 5} removals{ESC}[0m"
    if kind == 2:
        return tag + f"      {ESC}[48;5;22m{ESC}[38;5;255m+  let offset = viewport.top + rows * {n % 13} // keep the reader's place{ESC}[0m"
    if kind == 3:
        return tag + f"      {ESC}[48;5;52m{ESC}[38;5;255m-  scrollView.contentOffset.y = maxOffsetY{ESC}[0m"
    if kind == 4:
        return tag + f"{ESC}[38;5;246m⏺{ESC}[0m The pan reads rows the phone already holds; row {n} of the session, {ESC}[3mitalic{ESC}[0m and {ESC}[4munderlined{ESC}[0m words."
    if kind == 5:
        return tag + f"{ESC}[1;32m⏺{ESC}[0m {ESC}[1mBash{ESC}[0m(cargo test -p cmux-tui --lib scroll_{n})"
    if kind == 6:
        return tag + f"  ⎿  {ESC}[32mtest result: ok.{ESC}[0m {n % 200} passed; 0 failed; finished in 0.{n % 97:02d}s"
    if kind == 7:
        return tag + f"{ESC}[38;5;75m✓{ESC}[0m {ESC}[38;5;250mTodo {n % 8}: measure the pan under load{ESC}[0m"
    return tag + "    " + " ".join(f"{ESC}[38;5;{16 + (n * 7 + i) % 216}mword{i}{ESC}[0m" for i in range(8))


def live_region(tick: int, width: int) -> str:
    width = max(20, min(width, 200))
    bar = "─" * (width - 2)
    lines = [
        f"{ESC}[38;5;174m{SPIN[tick % len(SPIN)]}{ESC}[0m {ESC}[38;5;174mThinking…{ESC}[0m {ESC}[2m({tick // 60}s · ↓ {tick * 13 % 9000} tokens · esc to interrupt){ESC}[0m",
        f"{ESC}[2m╭{bar}╮{ESC}[0m",
        f"{ESC}[2m│{ESC}[0m > " + " " * max(0, width - 5) + f"{ESC}[2m│{ESC}[0m",
        f"{ESC}[2m╰{bar}╯{ESC}[0m",
        f"  {ESC}[2m? for shortcuts{ESC}[0m",
    ]
    return "".join(line[: width * 4] + "\r\n" for line in lines)


def width() -> int:
    try:
        return os.get_terminal_size(sys.stdout.fileno()).columns
    except OSError:
        return 80


def height() -> int:
    try:
        return os.get_terminal_size(sys.stdout.fileno()).lines
    except OSError:
        return 24


def out(text: str) -> None:
    os.write(sys.stdout.fileno(), text.encode())


def history(rows: int) -> None:
    batch = []
    for n in range(rows):
        batch.append(row(n) + "\r\n")
        if len(batch) == 200:
            out("".join(batch))
            batch = []
    if batch:
        out("".join(batch))


def primary(start: int, period: float) -> None:
    n, tick = start, 0
    out(live_region(tick, width()))
    while True:
        time.sleep(period)
        tick += 1
        n += 1
        out(f"{ESC}[{LIVE}F{ESC}[J" + row(n) + "\r\n" + live_region(tick, width()))


def alt(start: int, period: float) -> None:
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    tty.setraw(fd)
    log = [row(n) for n in range(max(0, start - 2000), start)]
    n, wheels, back, pending = start, 0, 0, b""
    out(f"{ESC}[?1049h{ESC}[?1000h{ESC}[?1006h{ESC}[?25l")

    def draw() -> None:
        h, w = height(), width()
        body = max(1, h - 2)
        end = max(body, len(log) - back)
        shown = log[end - body:end]
        frame = [f"{ESC}[H{ESC}[7m claude (full screen) · {len(log)} rows · view -{back} {ESC}[0m{ESC}[K"]
        for i in range(body):
            frame.append(f"{ESC}[{i + 2};1H{ESC}[2K" + (shown[i] if i < len(shown) else ""))
        frame.append(f"{ESC}[{h};1H{ESC}[2K{ESC}[7m WHEEL#{wheels} {ESC}[0m {ESC}[2mscroll to read · {w}x{h}{ESC}[0m")
        out("".join(frame))

    try:
        draw()
        due = time.monotonic() + period
        while True:
            ready, _, _ = select.select([fd], [], [], max(0.0, due - time.monotonic()))
            if ready:
                data = os.read(fd, 65536)
                if not data:
                    return
                pending += data
                moved = False
                while True:
                    start_at = pending.find(b"\x1b[<")
                    if start_at < 0:
                        pending = b""
                        break
                    end_at = -1
                    for i in range(start_at + 3, len(pending)):
                        if pending[i:i + 1] in (b"M", b"m"):
                            end_at = i
                            break
                    if end_at < 0:
                        pending = pending[start_at:]
                        break
                    button = pending[start_at + 3:end_at].split(b";")[0]
                    if button in (b"64", b"65"):
                        wheels += 1
                        back = max(0, min(len(log) - 1, back + (3 if button == b"64" else -3)))
                        moved = True
                    pending = pending[end_at + 1:]
                if moved:
                    draw()
            if time.monotonic() >= due:
                due += period
                n += 1
                log.append(row(n))
                if back:
                    back += 1
                draw()
    finally:
        out(f"{ESC}[?1006l{ESC}[?1000l{ESC}[?25h{ESC}[?1049l")
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


def main() -> None:
    mode, rows, period_ms, done = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    history(rows)
    with open(done, "w") as f:
        f.write(f"{rows}\n")
    if mode == "alt":
        alt(rows, period_ms / 1000)
    else:
        primary(rows, period_ms / 1000)


if __name__ == "__main__":
    main()
