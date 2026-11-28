from __future__ import annotations

import json
import os
import shutil
import socket
import tempfile
import threading
import time
import unittest
from typing import Any, Dict, List, Optional

import cmux
from cmux import AgentId, AgentSnapshot, SessionId, TerminalId, Unknown

from watchdog import AgentWatchdog, WatchdogConfig


MACHINE_ID = "machine_" + "1" * 32
SESSION_ID = "session_" + "2" * 32
WORKSPACE_ID = "ws_" + "3" * 32
SCREEN_ID = "screen_" + "4" * 32
PANE_ID = "pane_" + "5" * 32
TAB_ID = "tab_" + "6" * 32
TERMINAL_ID = "term_" + "7" * 32
AGENT_ID = "agent_" + "8" * 32
NOTIFICATION_ID = "notification_" + "9" * 32
GENERATION = "fake-generation"


def receive_frame(connection: socket.socket) -> Dict[str, Any]:
    buffer = bytearray()
    while True:
        chunk = connection.recv(4096)
        if not chunk:
            raise EOFError
        buffer.extend(chunk)
        newline = buffer.find(b"\n")
        if newline >= 0:
            return json.loads(bytes(buffer[:newline]).decode("utf-8"))


def send_frame(connection: socket.socket, value: Dict[str, Any]) -> None:
    connection.sendall(
        json.dumps(value, separators=(",", ":")).encode("utf-8") + b"\n"
    )


def response(request: Dict[str, Any], result: Any) -> Dict[str, Any]:
    return {
        "protocol": "cmux.protocol/2",
        "type": "response",
        "id": request["id"],
        "ok": True,
        "result": result,
    }


def full_snapshot(*, blocked: bool) -> Dict[str, Any]:
    agent = {
        "id": AGENT_ID,
        "session_id": SESSION_ID,
        "terminal_id": TERMINAL_ID,
        "state": "blocked",
        "source": "socket",
        "updated_at_ms": "1700000000000",
        "source_session": "codex-7",
    }
    return {
        "machine": {
            "id": MACHINE_ID,
            "name": "local",
            "origin": "local",
            "status": "running",
            "connectable": True,
            "deleted": False,
            "recoverable": False,
        },
        "session": {
            "id": SESSION_ID,
            "machine_id": MACHINE_ID,
            "name": "test",
            "generation": GENERATION,
            "revision": "1",
            "connected": True,
        },
        "workspaces": [
            {
                "id": WORKSPACE_ID,
                "session_id": SESSION_ID,
                "name": "watchdog-test",
                "index": 0,
                "focused": True,
            }
        ],
        "screens": [
            {
                "id": SCREEN_ID,
                "workspace_id": WORKSPACE_ID,
                "name": "agents",
                "index": 0,
                "focused": True,
                "layout": {
                    "version": 1,
                    "screen_id": SCREEN_ID,
                    "active_pane_id": PANE_ID,
                    "zoomed_pane_id": None,
                    "root": {
                        "kind": "leaf",
                        "pane_id": PANE_ID,
                        "tab_ids": [TAB_ID],
                        "active_tab_id": TAB_ID,
                    }
                },
            }
        ],
        "panes": [
            {
                "id": PANE_ID,
                "screen_id": SCREEN_ID,
                "name": "codex",
                "focused": True,
                "zoomed": False,
            }
        ],
        "tabs": [
            {
                "id": TAB_ID,
                "pane_id": PANE_ID,
                "name": "agent",
                "index": 0,
                "focused": True,
                "content_kind": "terminal",
                "content_id": TERMINAL_ID,
            }
        ],
        "terminals": [
            {
                "id": TERMINAL_ID,
                "tab_id": TAB_ID,
                "tab_ids": [TAB_ID],
                "title": "Codex",
                "cwd": "/tmp/project",
                "cols": 80,
                "rows": 24,
                "running": True,
                "lifecycle": "running",
            }
        ],
        "browsers": [],
        "clients": [],
        "notifications": [],
        "agents": [agent] if blocked else [],
        "frontend_projections": [],
        "sidebar_views": [],
        "cursor": {"generation": GENERATION, "revision": "1"},
    }


class FakeCmuxServer:
    def __init__(
        self,
        *,
        drop_first_stream: bool = False,
        screen_text: str = "$ codex\nWaiting for user approval",
        history_text: str = "history",
    ) -> None:
        self.drop_first_stream = drop_first_stream
        self.screen_text = screen_text
        self.history_text = history_text
        self.connection_count = 0
        self.event_stream_count = 0
        self.operations: List[str] = []
        self.notifications: List[Dict[str, Any]] = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._root = tempfile.mkdtemp(prefix="cmux-watchdog-", dir="/tmp")
        self.path = os.path.join(self._root, "session.sock")
        self._listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._listener.bind(self.path)
        self._listener.listen()
        self._listener.settimeout(0.05)
        self._threads: List[threading.Thread] = []
        self._accept_thread = threading.Thread(target=self._accept, daemon=True)
        self._accept_thread.start()

    def _accept(self) -> None:
        while not self._stop.is_set():
            try:
                connection, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with self._lock:
                self.connection_count += 1
                cycle = self.connection_count
            thread = threading.Thread(
                target=self._handle_connection,
                args=(connection, cycle),
                daemon=True,
            )
            self._threads.append(thread)
            thread.start()

    def _handle_connection(self, connection: socket.socket, cycle: int) -> None:
        with connection:
            while not self._stop.is_set():
                try:
                    request = receive_frame(connection)
                except (ConnectionError, EOFError, OSError):
                    return
                operation = request["operation"]
                with self._lock:
                    self.operations.append(operation)

                if operation == "session.events":
                    with self._lock:
                        self.event_stream_count += 1
                    send_frame(
                        connection,
                        response(request, {"stream_id": request["params"]["stream_id"]}),
                    )
                    if self.drop_first_stream and cycle == 1:
                        return
                    if not self.drop_first_stream:
                        send_frame(
                            connection,
                            {
                                "protocol": "cmux.protocol/2",
                                "type": "stream_item",
                                "stream_id": request["params"]["stream_id"],
                                "sequence": "1",
                                "item": {
                                    "kind": "agent-heartbeat-v2",
                                    "opaque_future_field": {"sequence": 99},
                                },
                            },
                        )
                elif operation == "session.snapshot":
                    send_frame(
                        connection,
                        response(
                            request,
                            full_snapshot(
                                blocked=self.drop_first_stream and cycle >= 2
                            ),
                        ),
                    )
                elif operation == "terminal.screen.read":
                    send_frame(
                        connection,
                        response(
                            request,
                            {
                                "text": self.screen_text,
                                "cols": 80,
                                "rows": 24,
                                "cursor_row": 1,
                                "cursor_col": 25,
                                "cursor_visible": True,
                            },
                        ),
                    )
                elif operation == "terminal.history.read":
                    send_frame(
                        connection,
                        response(
                            request,
                            {
                                "start": "0",
                                "next": "1",
                                "rows": [
                                    {
                                        "row": 0,
                                        "runs": [
                                            {
                                                "text": self.history_text,
                                                "fg": None,
                                                "bg": None,
                                                "attrs": 0,
                                            }
                                        ],
                                    }
                                ],
                            },
                        ),
                    )
                elif operation == "notification.create":
                    with self._lock:
                        self.notifications.append(dict(request["params"]))
                    send_frame(
                        connection,
                        response(
                            request,
                            {
                                "value": {
                                    "id": NOTIFICATION_ID,
                                    "session_id": SESSION_ID,
                                    "title": request["params"]["title"],
                                    "body": request["params"]["body"],
                                    "level": request["params"]["level"],
                                    "created_at_ms": "1700000060000",
                                    "unread": True,
                                    "terminal_id": request["params"]["terminal_id"],
                                },
                                "generation": GENERATION,
                                "revision": "2",
                                "replayed": False,
                            },
                        ),
                    )
                elif operation == "stream.cancel":
                    send_frame(connection, response(request, {}))
                else:
                    send_frame(
                        connection,
                        {
                            "protocol": "cmux.protocol/2",
                            "type": "response",
                            "id": request["id"],
                            "ok": False,
                            "error": {
                                "code": "unsupported",
                                "message": "unsupported fake operation " + operation,
                                "retryable": False,
                            },
                        },
                    )

    def close(self) -> None:
        self._stop.set()
        self._listener.close()
        self._accept_thread.join(timeout=1.0)
        for thread in self._threads:
            thread.join(timeout=1.0)
        shutil.rmtree(self._root, ignore_errors=True)

    def __enter__(self) -> "FakeCmuxServer":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()


class WatchdogTests(unittest.TestCase):
    def test_root_package_exposes_only_the_resource_client(self) -> None:
        self.assertTrue(hasattr(cmux, "Client"))
        self.assertFalse(hasattr(cmux, "CmuxClient"))
        self.assertFalse(hasattr(cmux, "AgentRecord"))

    def test_working_agent_becomes_stalled_at_the_configured_threshold(self) -> None:
        watchdog = AgentWatchdog(
            WatchdogConfig(stalled_after=60.0),
            wall_clock_ms=lambda: 1_700_000_060_000,
        )
        agent = AgentSnapshot(
            id=AgentId(AGENT_ID),
            session_id=SessionId(SESSION_ID),
            terminal_id=TerminalId(TERMINAL_ID),
            state="working",
            source="socket",
            updated_at_ms="1700000000000",
            source_session="codex-7",
        )

        self.assertEqual(
            watchdog._condition(agent, 1_700_000_060_000),
            ("stalled", 60_000),
        )
        self.assertIsNone(watchdog._condition(agent, 1_700_000_059_999))

    def test_unknown_resource_event_is_delivered_without_breaking_the_watchdog(
        self,
    ) -> None:
        observed: List[Unknown] = []
        holder: Dict[str, AgentWatchdog] = {}

        def record(event: object) -> None:
            if isinstance(event, Unknown):
                observed.append(event)
                holder["watchdog"].request_stop()

        with FakeCmuxServer() as server:
            watchdog = AgentWatchdog(
                WatchdogConfig(
                    socket_path=server.path,
                    poll_interval=0.05,
                    timeout=0.5,
                    reconnect_initial=0.01,
                    reconnect_max=0.02,
                    stable_connection_seconds=1.0,
                ),
                event_sink=record,
            )
            holder["watchdog"] = watchdog
            thread = threading.Thread(target=watchdog.run)
            thread.start()
            thread.join(timeout=2.0)
            watchdog.request_stop()
            thread.join(timeout=1.0)

        self.assertFalse(thread.is_alive())
        self.assertEqual([event.kind for event in observed], ["agent-heartbeat-v2"])
        self.assertEqual(observed[0].raw["opaque_future_field"]["sequence"], 99)
        self.assertEqual(server.event_stream_count, 1)

    def test_transport_loss_reconnects_resource_stream_and_notifies(self) -> None:
        with FakeCmuxServer(drop_first_stream=True) as server:
            watchdog = AgentWatchdog(
                WatchdogConfig(
                    socket_path=server.path,
                    poll_interval=0.02,
                    stalled_after=60.0,
                    timeout=0.5,
                    reconnect_initial=0.01,
                    reconnect_max=0.02,
                    stable_connection_seconds=1.0,
                ),
                wall_clock_ms=lambda: 1_700_000_060_000,
            )
            thread = threading.Thread(target=watchdog.run)
            thread.start()
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline and not server.notifications:
                time.sleep(0.01)
            watchdog.request_stop()
            thread.join(timeout=1.0)

        self.assertFalse(thread.is_alive())
        self.assertGreaterEqual(server.connection_count, 2)
        self.assertGreaterEqual(server.event_stream_count, 2)
        self.assertEqual(len(server.notifications), 1)
        notification = server.notifications[0]
        self.assertEqual(notification["level"], "warning")
        self.assertEqual(notification["terminal_id"], TERMINAL_ID)
        self.assertIn("Agent blocked", notification["title"])
        self.assertIn("Waiting for user approval", notification["body"])
        self.assertNotIn("identify", server.operations)
        self.assertNotIn("list-agents", server.operations)

    def test_empty_screen_falls_back_to_typed_history_rows(self) -> None:
        with FakeCmuxServer(
            drop_first_stream=True,
            screen_text=" \n",
            history_text="approval requested in history",
        ) as server:
            watchdog = AgentWatchdog(
                WatchdogConfig(
                    socket_path=server.path,
                    poll_interval=0.02,
                    stalled_after=60.0,
                    timeout=0.5,
                    reconnect_initial=0.01,
                    reconnect_max=0.02,
                    stable_connection_seconds=1.0,
                ),
                wall_clock_ms=lambda: 1_700_000_060_000,
            )
            thread = threading.Thread(target=watchdog.run)
            thread.start()
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline and not server.notifications:
                time.sleep(0.01)
            watchdog.request_stop()
            thread.join(timeout=1.0)

        self.assertFalse(thread.is_alive())
        self.assertEqual(len(server.notifications), 1)
        self.assertIn(
            "approval requested in history",
            server.notifications[0]["body"],
        )
        self.assertIn("terminal.history.read", server.operations)


if __name__ == "__main__":
    unittest.main()
