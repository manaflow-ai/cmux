#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from cmux import CommandError, CmuxClient, TimeoutError as CmuxTimeoutError  # noqa: E402


def main() -> int:
    socket_path = os.environ.get("CMUX_TUI_SOCKET") or os.environ.get("CMUX_MUX_SOCKET")
    if not socket_path:
        raise SystemExit("CMUX_TUI_SOCKET is required")
    marker = f"CMUX_PY_E2E_{os.getpid()}_{time.time_ns()}"
    later = f"{marker}_ATTACH"
    with CmuxClient(socket_path=socket_path, timeout=5.0, allow_protocol_v6_attach=True) as client:
        info = client.identify()
        assert info.app == "cmux-tui", info
        assert 5 <= info.protocol <= 6, info
        created = client.new_workspace(name=marker, cols=80, rows=24)
        client.send(created.surface, text=f"printf '{marker}\\n'\r")
        wait_for_marker(client, created.surface, marker)
        assert marker in client.read_screen(created.surface).text
        workspace = find_workspace_for_surface(client.list_workspaces(), created.surface)
        assert workspace is not None
        client.rename_surface(created.surface, f"{marker}-renamed")
        events = client.subscribe()
        try:
            client.resize_surface(created.surface, 100, 31)
            resized = next_resized(events, created.surface, 1.0)
            assert (resized.cols, resized.rows) == (100, 31)
            client.resize_surface(created.surface, 100, 31)
            try:
                next_resized(events, created.surface, 0.5)
            except CmuxTimeoutError:
                pass
            else:
                raise AssertionError("same-size resize emitted surface-resized")
        finally:
            events.close()
        attach = client.attach_surface(created.surface)
        try:
            first = next(attach)
            assert first.event == "vt-state", first
            client.send(created.surface, text=f"printf '{later}\\n'\r")
            next_attach_output(attach, 3.0)
        finally:
            attach.close()
        client.close_workspace(workspace)
        assert find_workspace_for_surface(client.list_workspaces(), created.surface) is None
        try:
            client.read_screen(created.surface)
        except CommandError as exc:
            assert exc.message
        else:
            raise AssertionError("read-screen on closed surface unexpectedly succeeded")
    return 0


def wait_for_marker(client: CmuxClient, surface: int, marker: str) -> None:
    deadline = time.time() + 5.0
    last = ""
    while time.time() < deadline:
        last = client.read_screen(surface).text
        if marker in last:
            return
        time.sleep(0.05)
    raise AssertionError(f"marker not found; last screen: {last!r}")


def next_resized(stream, surface: int, timeout: float):
    deadline = time.time() + timeout
    old_timeout = stream._conn.sock.gettimeout()
    stream._conn.sock.settimeout(timeout)
    try:
        while time.time() < deadline:
            stream._conn.sock.settimeout(max(deadline - time.time(), 0.001))
            event = next(stream)
            if event.event == "surface-resized" and event.surface == surface:
                return event
    finally:
        stream._conn.sock.settimeout(old_timeout)
    raise CmuxTimeoutError("surface-resized not observed")


def next_attach_output(stream, timeout: float) -> None:
    deadline = time.time() + timeout
    old_timeout = stream._conn.sock.gettimeout()
    stream._conn.sock.settimeout(timeout)
    try:
        while time.time() < deadline:
            stream._conn.sock.settimeout(max(deadline - time.time(), 0.001))
            event = next(stream)
            if event.event in ("output", "resized"):
                return
    finally:
        stream._conn.sock.settimeout(old_timeout)
    raise CmuxTimeoutError("attach output not observed")


def find_workspace_for_surface(tree, surface: int) -> int | None:
    for workspace in tree.workspaces:
        for screen in workspace.screens:
            for pane in screen.panes:
                if any(tab.surface == surface for tab in pane.tabs):
                    return workspace.id
    return None


if __name__ == "__main__":
    raise SystemExit(main())
