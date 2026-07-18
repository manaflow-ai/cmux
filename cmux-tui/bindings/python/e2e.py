#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
import time
from pathlib import Path
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parent))

from cmux import (  # noqa: E402
    CommandError,
    CmuxClient,
    TimeoutError as CmuxTimeoutError,
    TopologyCursor,
    TopologyDelta,
    TopologyOperation,
    TopologyResnapshotReason,
    TopologyResnapshotRequired,
    TopologyStream,
)


def main() -> int:
    socket_path = os.environ.get("CMUX_TUI_SOCKET") or os.environ.get("CMUX_MUX_SOCKET")
    if not socket_path:
        raise SystemExit("CMUX_TUI_SOCKET is required")
    marker = f"CMUX_PY_E2E_{os.getpid()}_{time.time_ns()}"
    later = f"{marker}_ATTACH"
    with CmuxClient(socket_path=socket_path, timeout=5.0, allow_protocol_v6_attach=True) as client:
        info = client.identify()
        assert info.app == "cmux-tui", info
        assert 5 <= info.protocol <= 8, info
        assert info.supports_topology_v8, info
        assert info.topology_cursor is not None, info
        ping = client.ping()
        assert ping.ok, ping
        assert ping.session_id == info.session_id, (ping, info)
        assert ping.daemon_instance_id == info.daemon_instance_id, (ping, info)
        assert ping.topology_revision == info.topology_revision, (ping, info)
        assert ping.canonical_topology_revision == info.topology_cursor.revision, (ping, info)
        created = client.new_workspace(name=marker, cols=80, rows=24)
        client.send(created.surface, text=f"printf '{marker}\\n'\r")
        wait_for_marker(client, created.surface, marker)
        assert marker in client.read_screen(created.surface).text
        workspace = find_workspace_for_surface(client.list_workspaces(), created.surface)
        assert workspace is not None
        snapshot = client.topology_snapshot()
        canonical = next(
            item
            for item in snapshot.topology.workspaces
            if any(
                tab.id == created.surface
                for screen in item.screens
                for pane in screen.panes
                for tab in pane.tabs
            )
        )
        assert canonical.id == workspace
        topology = client.subscribe_topology(snapshot.cursor)
        assert isinstance(topology, TopologyStream), topology
        client.rename_workspace(workspace, f"{marker}-topology")
        delta = next_topology(topology, 2.0)
        assert isinstance(delta, TopologyDelta), delta
        assert delta.operation == TopologyOperation.WORKSPACE_RENAMED
        assert delta.base_revision == snapshot.revision
        assert delta.revision == snapshot.revision + 1
        topology.close()
        stale = client.subscribe_topology(
            TopologyCursor(
                UUID("00000000-0000-0000-0000-000000000001"),
                snapshot.session_id,
                snapshot.revision,
            )
        )
        assert isinstance(stale, TopologyResnapshotRequired), stale
        assert stale.reason == TopologyResnapshotReason.STALE_DAEMON
        events = client.subscribe()
        try:
            title = f"{marker}_TITLE"
            client.send(created.surface, text=f"printf '\\033]2;{title}\\007'; sleep 30\r")
            title_changed = next_title_changed(events, created.surface, title, 3.0)
            assert title_changed.title == title, title_changed
            client.send(created.surface, text="\x03")
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
        client.rename_surface(created.surface, f"{marker}-renamed")
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


def next_title_changed(stream, surface: int, title: str, timeout: float):
    deadline = time.time() + timeout
    old_timeout = stream._conn.sock.gettimeout()
    stream._conn.sock.settimeout(timeout)
    try:
        while time.time() < deadline:
            stream._conn.sock.settimeout(max(deadline - time.time(), 0.001))
            event = next(stream)
            if (
                event.event == "title-changed"
                and event.surface == surface
                and event.title == title
            ):
                return event
    finally:
        stream._conn.sock.settimeout(old_timeout)
    raise CmuxTimeoutError("title-changed not observed")


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


def next_topology(stream: TopologyStream, timeout: float):
    old_timeout = stream._conn.sock.gettimeout()
    stream._conn.sock.settimeout(timeout)
    try:
        return next(stream)
    finally:
        stream._conn.sock.settimeout(old_timeout)


def find_workspace_for_surface(tree, surface: int) -> int | None:
    for workspace in tree.workspaces:
        for screen in workspace.screens:
            for pane in screen.panes:
                if any(tab.surface == surface for tab in pane.tabs):
                    return workspace.id
    return None


if __name__ == "__main__":
    raise SystemExit(main())
