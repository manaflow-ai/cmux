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

from cmux import AgentRecord, AgentSource, AgentState, UnknownEvent

from watchdog import AgentWatchdog, WatchdogConfig


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


class FakeCmuxServer:
    def __init__(self, *, drop_first_coarse: bool = False) -> None:
        self.drop_first_coarse = drop_first_coarse
        self.identify_count = 0
        self.notifications: List[Dict[str, Any]] = []
        self.subscriptions: List[str] = []
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
            thread = threading.Thread(
                target=self._handle_connection,
                args=(connection,),
                daemon=True,
            )
            self._threads.append(thread)
            thread.start()

    def _handle_connection(self, connection: socket.socket) -> None:
        with connection:
            try:
                first = receive_frame(connection)
                if first["cmd"] == "subscribe":
                    self._handle_subscription(connection, first)
                else:
                    self._handle_commands(connection, first)
            except (BrokenPipeError, ConnectionError, EOFError, OSError):
                return

    def _handle_subscription(
        self, connection: socket.socket, request: Dict[str, Any]
    ) -> None:
        mode = request.get("tree_events", "coarse")
        with self._lock:
            self.subscriptions.append(mode)
            ordinal = len(self.subscriptions)
        send_frame(connection, {"id": request["id"], "ok": True, "data": {}})

        if self.drop_first_coarse and mode == "coarse" and ordinal == 1:
            return
        if not self.drop_first_coarse and mode == "coarse":
            send_frame(
                connection,
                {
                    "event": "agent-heartbeat-v2",
                    "surface": 7,
                    "opaque_future_field": {"sequence": 99},
                },
            )
        self._stop.wait(2.0)

    def _handle_commands(
        self, connection: socket.socket, request: Dict[str, Any]
    ) -> None:
        cycle = 0
        current: Optional[Dict[str, Any]] = request
        while current is not None:
            command = current["cmd"]
            if command == "identify":
                with self._lock:
                    self.identify_count += 1
                    cycle = self.identify_count
                data: Dict[str, Any] = {
                    "app": "cmux-tui",
                    "daemon_handoff": 1,
                    "generation": "generation-" + str(cycle),
                    "pid": 4100 + cycle,
                    "protocol": 10,
                    "registry_id": "registry",
                    "session": "test",
                    "terminal_revision": 0,
                    "version": "test",
                    "workspace_revision": 0,
                    "capabilities": [],
                }
            elif command == "set-client-info":
                data = {}
            elif command == "list-workspaces":
                data = {"workspaces": []}
            elif command == "list-agents":
                agents: List[Dict[str, Any]] = []
                if self.drop_first_coarse and cycle >= 2:
                    agents.append(
                        {
                            "surface": 7,
                            "session": "codex-7",
                            "source": "socket",
                            "state": "blocked",
                            "updated_at_ms": 1_700_000_000_000,
                        }
                    )
                data = {"agents": agents}
            elif command == "read-screen":
                data = {"text": "$ codex\nWaiting for user approval"}
            elif command == "notify":
                with self._lock:
                    self.notifications.append(dict(current))
                data = {"notification": 81}
            else:
                send_frame(
                    connection,
                    {
                        "id": current["id"],
                        "ok": False,
                        "error": "unsupported fake command " + command,
                    },
                )
                current = receive_frame(connection)
                continue

            send_frame(
                connection,
                {"id": current["id"], "ok": True, "data": data},
            )
            current = receive_frame(connection)

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
    def test_working_agent_becomes_stalled_at_the_configured_threshold(self) -> None:
        watchdog = AgentWatchdog(
            WatchdogConfig(stalled_after=60.0),
            wall_clock_ms=lambda: 1_700_000_060_000,
        )
        agent = AgentRecord(
            surface=7,
            session="codex-7",
            source=AgentSource.SOCKET,
            state=AgentState.WORKING,
            updated_at_ms=1_700_000_000_000,
        )

        self.assertEqual(
            watchdog._condition(agent, 1_700_000_060_000),
            ("stalled", 60_000),
        )
        self.assertIsNone(watchdog._condition(agent, 1_700_000_059_999))

    def test_unknown_event_is_delivered_without_breaking_the_watchdog(self) -> None:
        observed: List[UnknownEvent] = []
        holder: Dict[str, AgentWatchdog] = {}

        def record(_source: str, event: object) -> None:
            if isinstance(event, UnknownEvent):
                observed.append(event)
                holder["watchdog"].request_stop()

        with FakeCmuxServer() as server:
            watchdog = AgentWatchdog(
                WatchdogConfig(
                    socket_path=server.path,
                    poll_interval=0.05,
                    stalled_after=60.0,
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
        self.assertEqual([event.event for event in observed], ["agent-heartbeat-v2"])
        self.assertEqual(observed[0].raw["opaque_future_field"]["sequence"], 99)
        self.assertIn("coarse", server.subscriptions)
        self.assertIn("deltas", server.subscriptions)

    def test_transport_loss_reconnects_and_restores_both_subscriptions(self) -> None:
        with FakeCmuxServer(drop_first_coarse=True) as server:
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
        self.assertGreaterEqual(server.identify_count, 2)
        self.assertGreaterEqual(server.subscriptions.count("coarse"), 2)
        self.assertGreaterEqual(server.subscriptions.count("deltas"), 2)
        self.assertEqual(len(server.notifications), 1)
        notification = server.notifications[0]
        self.assertEqual(notification["level"], "warning")
        self.assertEqual(notification["surface"], 7)
        self.assertIn("Agent blocked", notification["title"])
        self.assertIn("Waiting for user approval", notification["body"])


if __name__ == "__main__":
    unittest.main()
