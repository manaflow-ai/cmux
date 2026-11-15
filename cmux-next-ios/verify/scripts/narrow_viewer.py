"""A narrower second viewer of this terminal, for the pair-e2e sizing capture.

Run inside a cmux terminal: connects to its daemon ($CMUX_TUI_SOCKET) as a
desktop view of this Mac, attaches to this terminal ($CMUX_TUI_TERMINAL_ID)
claiming 39x26 (the Mac pane of Leo's report, 2026-11-15), keeps that view
attached, and redraws a column ruler with the grid size every 2 s, so a phone
screenshot shows where the grid wraps.
"""

import fcntl
import json
import os
import socket
import struct
import sys
import termios
import threading
import time

COLS, ROWS = 39, 26


def main():
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.connect(os.environ["CMUX_TUI_SOCKET"])
    replies = {}
    ready = threading.Condition()

    def read():
        buf = b""
        while True:
            chunk = conn.recv(1 << 20)
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if isinstance(message, dict) and "id" in message and "event" not in message:
                    with ready:
                        replies[message["id"]] = message
                        ready.notify_all()

    threading.Thread(target=read, daemon=True).start()

    def call(number, request):
        request["id"] = number
        conn.sendall((json.dumps(request) + "\n").encode())
        with ready:
            ready.wait_for(lambda: number in replies, timeout=20)
        return replies.get(number, {})

    terminal = os.environ.get("CMUX_TUI_TERMINAL_ID", "")
    listed = call(1, {"cmd": "list-terminals"})
    surface = find_surface(listed, terminal)
    print(f"narrow viewer: terminal {terminal} is surface {surface}", flush=True)
    call(2, {"cmd": "set-client-info", "kind": "frontend", "device_kind": "mac",
             "device_name": "narrow pane", "capabilities": ["shared-sizing-v1"]})
    attached = call(3, {"cmd": "attach-surface", "surface": surface, "cols": COLS, "rows": ROWS})
    print(f"narrow viewer: attached {COLS}x{ROWS}: {str(attached)[:120]}", flush=True)
    ruler = "".join(str(n % 10) for n in range(1, 201))
    while True:
        rows, cols = struct.unpack("hh", fcntl.ioctl(sys.stdout.fileno(), termios.TIOCGWINSZ, b"\0" * 4))
        sys.stdout.write(f"\033[H\033[2Jgrid {cols}x{rows}, second viewer {COLS}x{ROWS}\n{ruler}\n")
        sys.stdout.flush()
        time.sleep(2)


def find_surface(value, terminal):
    """The numeric surface id of the object in `value` that names `terminal`."""
    if isinstance(value, dict):
        if terminal and terminal in [v for v in value.values() if isinstance(v, str)]:
            for key in ("surface", "surface_id", "id"):
                if isinstance(value.get(key), int):
                    return value[key]
        for child in value.values():
            found = find_surface(child, terminal)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_surface(child, terminal)
            if found is not None:
                return found
    return None


if __name__ == "__main__":
    main()
