"""Deterministic cmux.protocol/2 server for the offline example and tests."""

from __future__ import annotations

import copy
import json
import os
import re
import shutil
import socket
import tempfile
import threading
from dataclasses import dataclass
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple


PROTOCOL = "cmux.protocol/2"
MACHINE_A = "machine_" + "a" * 32
SESSION_A = "session_" + "b" * 32
MACHINE_B = "machine_" + "c" * 32
SESSION_B = "session_" + "d" * 32
GENERATION = "fake-generation-1"


def _send_frame(connection: socket.socket, value: Mapping[str, Any]) -> None:
    connection.sendall(
        json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")
        + b"\n"
    )


@dataclass
class _ConnectionState:
    connection: socket.socket
    stream_id: Optional[str] = None
    stream_session_id: Optional[str] = None
    stream_sequence: int = 0


class FakeCmuxServer:
    """Stateful fake with one deterministic local machine and session by default."""

    def __init__(
        self,
        *,
        duplicate_session_name: bool = False,
        workspace_create_indeterminate: Optional[str] = None,
        workspace_close_indeterminate: Optional[str] = None,
        pane_split_indeterminate: Optional[str] = None,
        replayed_operations: Sequence[str] = (),
    ) -> None:
        for value in (
            workspace_create_indeterminate,
            workspace_close_indeterminate,
            pane_split_indeterminate,
        ):
            if value not in (None, "applied", "not_applied"):
                raise ValueError(
                    "indeterminate outcome must be applied, not_applied, or None"
                )

        self.workspace_create_indeterminate = workspace_create_indeterminate
        self.workspace_close_indeterminate = workspace_close_indeterminate
        self.pane_split_indeterminate = pane_split_indeterminate
        self.replayed_operations = set(replayed_operations)
        self.requests: List[dict] = []
        self.errors: List[BaseException] = []

        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._root = tempfile.mkdtemp(prefix="cmux-python-dev-")
        self.path = os.path.join(self._root, "cmux.sock")
        self._listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._listener.bind(self.path)
        self._listener.listen()
        self._listener.settimeout(0.05)
        self._connections: List[socket.socket] = []
        self._threads: List[threading.Thread] = []
        self._receipts: Dict[str, Tuple[str, str, dict]] = {}
        self._creations: Dict[str, dict] = {}
        self._indeterminate_sent: set[str] = set()
        self._next_ids = {
            "ws": 0x10,
            "screen": 0x20,
            "pane": 0x30,
            "tab": 0x40,
            "term": 0x50,
            "split": 0x60,
        }

        self.machines = [
            self._machine_snapshot(MACHINE_A, "local-dev"),
        ]
        self.sessions_by_machine: Dict[str, List[dict]] = {
            MACHINE_A: [self._session_snapshot(SESSION_A, MACHINE_A, "main")],
        }
        if duplicate_session_name:
            self.machines.append(self._machine_snapshot(MACHINE_B, "remote-dev"))
            self.sessions_by_machine[MACHINE_B] = [
                self._session_snapshot(SESSION_B, MACHINE_B, "main")
            ]

        self.revisions: Dict[str, int] = {
            session["id"]: 0
            for sessions in self.sessions_by_machine.values()
            for session in sessions
        }
        self.workspaces: Dict[str, List[dict]] = {
            session_id: [] for session_id in self.revisions
        }
        self.screens: Dict[str, dict] = {}
        self.panes: Dict[str, dict] = {}
        self.tabs: Dict[str, dict] = {}
        self.terminals: Dict[str, dict] = {}
        self.terminal_output: Dict[str, str] = {}

        self._accept_thread = threading.Thread(
            target=self._accept_loop,
            name="fake-cmux-accept",
            daemon=True,
        )
        self._accept_thread.start()

    @staticmethod
    def _machine_snapshot(machine_id: str, name: str) -> dict:
        return {
            "id": machine_id,
            "name": name,
            "origin": "local",
            "status": "running",
            "connectable": True,
            "deleted": False,
            "recoverable": False,
        }

    def _session_snapshot(
        self,
        session_id: str,
        machine_id: str,
        name: str,
    ) -> dict:
        revision = getattr(self, "revisions", {}).get(session_id, 0)
        return {
            "id": session_id,
            "machine_id": machine_id,
            "name": name,
            "generation": GENERATION,
            "revision": str(revision),
            "connected": True,
        }

    def _new_id(self, prefix: str) -> str:
        with self._lock:
            value = self._next_ids[prefix]
            self._next_ids[prefix] += 1
        return f"{prefix}_{value:032x}"

    def seed_workspace(self, name: str, *, session_id: str = SESSION_A) -> str:
        with self._lock:
            workspace_id = self._new_id("ws")
            values = self.workspaces[session_id]
            values.append(
                {
                    "id": workspace_id,
                    "session_id": session_id,
                    "name": name,
                    "index": len(values),
                    "focused": False,
                }
            )
            self.revisions[session_id] += 1
            return workspace_id

    def workspace_ids(
        self,
        name: Optional[str] = None,
        *,
        session_id: str = SESSION_A,
    ) -> List[str]:
        with self._lock:
            return [
                workspace["id"]
                for workspace in self.workspaces[session_id]
                if name is None or workspace["name"] == name
            ]

    def operations(self) -> List[str]:
        with self._lock:
            return [request["operation"] for request in self.requests]

    def _accept_loop(self) -> None:
        while not self._stop.is_set():
            try:
                connection, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with self._lock:
                self._connections.append(connection)
            thread = threading.Thread(
                target=self._serve_connection,
                args=(connection,),
                name="fake-cmux-client",
                daemon=True,
            )
            with self._lock:
                self._threads.append(thread)
            thread.start()

    def _serve_connection(self, connection: socket.socket) -> None:
        state = _ConnectionState(connection)
        try:
            with connection, connection.makefile("rb") as source:
                for line in source:
                    request = json.loads(line)
                    if not isinstance(request, dict):
                        raise ValueError("request frame must be an object")
                    with self._lock:
                        self.requests.append(copy.deepcopy(request))
                    self._dispatch(state, request)
        except (BrokenPipeError, ConnectionError, EOFError, OSError):
            pass
        except BaseException as error:
            with self._lock:
                self.errors.append(error)

    def _ok(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        result: Any,
    ) -> None:
        _send_frame(
            state.connection,
            {
                "protocol": PROTOCOL,
                "type": "response",
                "id": request["id"],
                "ok": True,
                "result": result,
            },
        )

    def _error(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        *,
        code: str,
        message: str,
        details: Any,
        retryable: bool = False,
    ) -> None:
        _send_frame(
            state.connection,
            {
                "protocol": PROTOCOL,
                "type": "response",
                "id": request["id"],
                "ok": False,
                "error": {
                    "code": code,
                    "message": message,
                    "details": details,
                    "retryable": retryable,
                },
            },
        )

    def _dispatch(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
    ) -> None:
        if request.get("protocol") != PROTOCOL or request.get("type") != "request":
            raise ValueError("wrong request envelope")
        operation = request.get("operation")
        params = request.get("params")
        if not isinstance(operation, str) or not isinstance(params, dict):
            raise ValueError("request omitted operation or params")

        if operation == "machine.list":
            self._ok(state, request, copy.deepcopy(self.machines))
        elif operation == "session.list":
            machine_id = self._resolve_machine(params.get("machine"))
            sessions = [
                self._current_session_snapshot(item["id"])
                for item in self.sessions_by_machine[machine_id]
            ]
            self._ok(state, request, sessions)
        elif operation == "session.get":
            session_id = self._resolve_session(params.get("session"))
            self._ok(state, request, self._current_session_snapshot(session_id))
        elif operation == "workspace.list":
            session_id = self._resolve_session(params.get("session"))
            self._ok(
                state,
                request,
                copy.deepcopy(self.workspaces[session_id]),
            )
        elif operation == "workspace.get":
            session_id = self._resolve_session(params.get("session"))
            workspace = self._workspace(params.get("workspace"), session_id)
            self._ok(state, request, copy.deepcopy(workspace))
        elif operation == "session.events":
            self._open_events(state, request, params)
        elif operation == "session.creation.resolve":
            self._resolve_creation(state, request, params)
        elif operation == "stream.cancel":
            self._cancel_events(state, request)
        elif operation == "workspace.create":
            self._create_workspace(state, request, params)
        elif operation == "screen.create":
            self._create_screen(state, request, params)
        elif operation == "pane.split":
            self._split_pane(state, request, params)
        elif operation == "tab.create_terminal":
            self._create_terminal_tab(state, request, params)
        elif operation == "pane.run":
            self._run_in_pane(state, request, params)
        elif operation == "terminal.wait":
            self._wait_terminal(state, request, params)
        elif operation == "terminal.wait_exit":
            self._wait_terminal_exit(state, request, params)
        elif operation == "workspace.close":
            self._close_workspace(state, request, params)
        else:
            self._error(
                state,
                request,
                code="operation.unsupported",
                message="fake server does not implement operation",
                details={"operation": operation},
            )

    def _resolve_machine(self, selector: Any) -> str:
        if selector == "current":
            return MACHINE_A
        if isinstance(selector, str) and selector in self.sessions_by_machine:
            return selector
        raise ValueError(f"unknown machine selector {selector!r}")

    def _resolve_session(self, selector: Any) -> str:
        if selector == "current":
            return SESSION_A
        if isinstance(selector, str) and selector in self.revisions:
            return selector
        raise ValueError(f"unknown session selector {selector!r}")

    def _current_session_snapshot(self, session_id: str) -> dict:
        for machine_id, sessions in self.sessions_by_machine.items():
            for session in sessions:
                if session["id"] == session_id:
                    return self._session_snapshot(
                        session_id,
                        machine_id,
                        session["name"],
                    )
        raise ValueError(f"unknown session ID {session_id}")

    def _workspace(self, selector: Any, session_id: str) -> dict:
        if not isinstance(selector, str):
            raise ValueError("workspace selector must be a string")
        if selector.startswith("name:"):
            name = selector[5:]
            matches = [
                item for item in self.workspaces[session_id] if item["name"] == name
            ]
        else:
            matches = [
                item for item in self.workspaces[session_id] if item["id"] == selector
            ]
        if len(matches) != 1:
            raise ValueError(f"workspace selector matched {len(matches)} resources")
        return matches[0]

    def _open_events(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        params: Mapping[str, Any],
    ) -> None:
        stream_id = params.get("stream_id")
        if not isinstance(stream_id, str):
            raise ValueError("session.events omitted stream_id")
        session_id = self._resolve_session(params.get("session"))
        state.stream_id = stream_id
        state.stream_session_id = session_id
        state.stream_sequence = 0
        self._ok(state, request, {"stream_id": stream_id})
        cursor = {
            "generation": GENERATION,
            "revision": str(self.revisions[session_id]),
        }
        _send_frame(
            state.connection,
            {
                "protocol": PROTOCOL,
                "type": "stream_item",
                "stream_id": stream_id,
                "sequence": "0",
                "cursor": cursor,
                "item": {
                    "kind": "snapshot",
                    "cursor": cursor,
                    "reset_reason": "initial",
                    "snapshot": self._full_snapshot(session_id),
                },
            },
        )

    def _cancel_events(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
    ) -> None:
        stream_id = state.stream_id
        if stream_id is not None:
            _send_frame(
                state.connection,
                {
                    "protocol": PROTOCOL,
                    "type": "stream_end",
                    "stream_id": stream_id,
                    "reason": "canceled",
                },
            )
            state.stream_id = None
            state.stream_session_id = None
        self._ok(state, request, {})

    def _full_snapshot(self, session_id: str) -> dict:
        session = self._current_session_snapshot(session_id)
        machine_id = session["machine_id"]
        machine = next(item for item in self.machines if item["id"] == machine_id)
        workspace_ids = {
            item["id"] for item in self.workspaces.get(session_id, [])
        }
        screens = [
            copy.deepcopy(item)
            for item in self.screens.values()
            if item["workspace_id"] in workspace_ids
        ]
        screen_ids = {item["id"] for item in screens}
        panes = [
            copy.deepcopy(item)
            for item in self.panes.values()
            if item["screen_id"] in screen_ids
        ]
        pane_ids = {item["id"] for item in panes}
        tabs = [
            copy.deepcopy(item)
            for item in self.tabs.values()
            if item["pane_id"] in pane_ids
        ]
        tab_ids = {item["id"] for item in tabs}
        terminals = [
            copy.deepcopy(item)
            for item in self.terminals.values()
            if any(tab_id in tab_ids for tab_id in item["tab_ids"])
        ]
        cursor = {
            "generation": GENERATION,
            "revision": str(self.revisions[session_id]),
        }
        return {
            "machine": copy.deepcopy(machine),
            "session": session,
            "workspaces": copy.deepcopy(self.workspaces[session_id]),
            "screens": screens,
            "panes": panes,
            "tabs": tabs,
            "terminals": terminals,
            "browsers": [],
            "clients": [],
            "notifications": [],
            "agents": [],
            "frontend_projections": [],
            "sidebar_views": [],
            "cursor": cursor,
        }

    def _emit_delta(
        self,
        state: _ConnectionState,
        session_id: str,
        previous_revision: int,
        changes: Sequence[Mapping[str, Any]],
    ) -> None:
        if (
            state.stream_id is None
            or state.stream_session_id != session_id
        ):
            return
        state.stream_sequence += 1
        revision = self.revisions[session_id]
        cursor = {
            "generation": GENERATION,
            "revision": str(revision),
        }
        _send_frame(
            state.connection,
            {
                "protocol": PROTOCOL,
                "type": "stream_item",
                "stream_id": state.stream_id,
                "sequence": str(state.stream_sequence),
                "cursor": cursor,
                "item": {
                    "kind": "delta",
                    "cursor": cursor,
                    "previous_revision": str(previous_revision),
                    "revision": str(revision),
                    "changes": list(changes),
                },
            },
        )

    def _expected_revision(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        params: Mapping[str, Any],
        session_id: str,
    ) -> bool:
        expected = params.get("expected_revision")
        if expected is None or expected == str(self.revisions[session_id]):
            return True
        self._error(
            state,
            request,
            code="revision.conflict",
            message="expected revision did not match",
            details={
                "expected": expected,
                "actual": str(self.revisions[session_id]),
            },
            retryable=True,
        )
        return False

    def _replay_if_known(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        operation: str,
        params: Mapping[str, Any],
    ) -> bool:
        key = request.get("idempotency_key")
        if not isinstance(key, str):
            raise ValueError(f"{operation} omitted idempotency_key")
        fingerprint = json.dumps(params, sort_keys=True, separators=(",", ":"))
        known = self._receipts.get(key)
        if known is None:
            return False
        known_operation, known_fingerprint, result = known
        if (known_operation, known_fingerprint) != (operation, fingerprint):
            self._error(
                state,
                request,
                code="idempotency.conflict",
                message="idempotency key was reused with different input",
                details={"idempotency_key": key},
            )
            return True
        replay = copy.deepcopy(result)
        replay["replayed"] = True
        self._ok(state, request, replay)
        return True

    def _finish_mutation(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        operation: str,
        params: Mapping[str, Any],
        result: dict,
    ) -> None:
        key = request.get("idempotency_key")
        if not isinstance(key, str):
            raise ValueError(f"{operation} omitted idempotency_key")
        if operation in self.replayed_operations:
            result["replayed"] = True
        fingerprint = json.dumps(params, sort_keys=True, separators=(",", ":"))
        self._receipts[key] = (
            operation,
            fingerprint,
            copy.deepcopy(result),
        )
        self._ok(state, request, result)

    def _mutation_result(
        self,
        value: Any,
        session_id: str,
        *,
        replayed: bool = False,
    ) -> dict:
        return {
            "value": value,
            "generation": GENERATION,
            "revision": str(self.revisions[session_id]),
            "replayed": replayed,
        }

    def _indeterminate(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        operation: str,
    ) -> None:
        self._error(
            state,
            request,
            code="mutation.indeterminate",
            message="the external effect may have completed",
            details={
                "idempotency_key": request["idempotency_key"],
                "operation": operation,
                "recovery": "inspect_state_then_retry_with_new_key",
            },
        )

    def _record_creation(
        self,
        request: Mapping[str, Any],
        operation: str,
        params: Mapping[str, Any],
        created_path: Mapping[str, Any],
        session_id: str,
    ) -> None:
        correlation = params.get("correlation_key")
        if not isinstance(correlation, str) or not correlation:
            raise ValueError(f"{operation} omitted correlation_key")
        self._creations[correlation] = {
            "correlation_key": correlation,
            "state": "created",
            "recovery": "none",
            "operation": operation,
            "idempotency_key": request["idempotency_key"],
            "created_path": copy.deepcopy(created_path),
            "generation": GENERATION,
            "revision": str(self.revisions[session_id]),
        }

    def _record_not_applied(
        self,
        request: Mapping[str, Any],
        operation: str,
        params: Mapping[str, Any],
    ) -> None:
        correlation = params.get("correlation_key")
        if not isinstance(correlation, str) or not correlation:
            raise ValueError(f"{operation} omitted correlation_key")
        self._creations[correlation] = {
            "correlation_key": correlation,
            "state": "not_applied",
            "recovery": "retry_new_idempotency_key",
            "operation": operation,
            "idempotency_key": request["idempotency_key"],
        }

    def _resolve_creation(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        params: Mapping[str, Any],
    ) -> None:
        correlation = params.get("correlation_key")
        if not isinstance(correlation, str) or not correlation:
            raise ValueError("session.creation.resolve omitted correlation_key")
        result = self._creations.get(
            correlation,
            {
                "correlation_key": correlation,
                "state": "not_applied",
                "recovery": "retry_new_idempotency_key",
            },
        )
        self._ok(state, request, copy.deepcopy(result))

    def _create_workspace(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        params: Mapping[str, Any],
    ) -> None:
        operation = "workspace.create"
        if self._replay_if_known(state, request, operation, params):
            return
        session_id = self._resolve_session(params.get("session"))
        outcome = self.workspace_create_indeterminate
        if outcome is not None and operation not in self._indeterminate_sent:
            self._indeterminate_sent.add(operation)
            if outcome == "applied":
                value = self._apply_workspace_create(state, params, session_id)
                self._record_creation(
                    request,
                    operation,
                    params,
                    value,
                    session_id,
                )
            else:
                self._record_not_applied(request, operation, params)
            self._indeterminate(state, request, operation)
            return

        value = self._apply_workspace_create(state, params, session_id)
        self._record_creation(request, operation, params, value, session_id)
        result = self._mutation_result(value, session_id)
        self._finish_mutation(state, request, operation, params, result)

    def _apply_workspace_create(
        self,
        state: _ConnectionState,
        params: Mapping[str, Any],
        session_id: str,
    ) -> dict:
        if params.get("initial_content") != "empty":
            raise ValueError("fake requires an empty workspace create")
        previous = self.revisions[session_id]
        workspace_id = self._new_id("ws")
        values = self.workspaces[session_id]
        snapshot = {
            "id": workspace_id,
            "session_id": session_id,
            "name": params.get("name") or "",
            "index": len(values),
            "focused": False,
        }
        values.append(snapshot)
        self.revisions[session_id] += 1
        self._emit_delta(
            state,
            session_id,
            previous,
            [
                {
                    "kind": "upsert",
                    "sequence": 0,
                    "resource": "workspace",
                    "id": workspace_id,
                    "value": copy.deepcopy(snapshot),
                }
            ],
        )
        return {"kind": "workspace", "workspace_id": workspace_id}

    def _create_screen(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        params: Mapping[str, Any],
    ) -> None:
        operation = "screen.create"
        if self._replay_if_known(state, request, operation, params):
            return
        session_id = self._resolve_session(params.get("session"))
        if not self._expected_revision(state, request, params, session_id):
            return
        workspace = self._workspace(params.get("workspace"), session_id)
        previous = self.revisions[session_id]
        screen_id = self._new_id("screen")
        pane_id = self._new_id("pane")
        tab_id = self._new_id("tab")
        terminal_id = self._new_id("term")
        self.screens[screen_id] = {
            "id": screen_id,
            "workspace_id": workspace["id"],
            "name": params.get("name"),
            "index": 0,
            "focused": False,
            "layout": {
                "version": 1,
                "screen_id": screen_id,
                "active_pane_id": pane_id,
                "zoomed_pane_id": None,
                "root": {
                    "kind": "leaf",
                    "pane_id": pane_id,
                    "tab_ids": [tab_id],
                    "active_tab_id": tab_id,
                },
            },
        }
        self.panes[pane_id] = {
            "id": pane_id,
            "screen_id": screen_id,
            "name": None,
            "focused": False,
            "zoomed": False,
        }
        self._add_terminal(tab_id, terminal_id, pane_id, None, params.get("cwd"))
        self.revisions[session_id] += 1
        self._emit_delta(state, session_id, previous, [])
        result = self._mutation_result(
            self._terminal_path(
                workspace["id"],
                screen_id,
                pane_id,
                tab_id,
                terminal_id,
            ),
            session_id,
        )
        self._record_creation(
            request,
            operation,
            params,
            result["value"],
            session_id,
        )
        self._finish_mutation(state, request, operation, params, result)

    def _split_pane(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        params: Mapping[str, Any],
    ) -> None:
        operation = "pane.split"
        if self._replay_if_known(state, request, operation, params):
            return
        session_id = self._resolve_session(params.get("session"))
        if not self._expected_revision(state, request, params, session_id):
            return
        outcome = self.pane_split_indeterminate
        indeterminate_after_apply = False
        if outcome is not None and operation not in self._indeterminate_sent:
            self._indeterminate_sent.add(operation)
            if outcome == "not_applied":
                self._record_not_applied(request, operation, params)
                self._indeterminate(state, request, operation)
                return
            indeterminate_after_apply = True
        source = self.panes[str(params["pane"])]
        screen = self.screens[source["screen_id"]]
        previous = self.revisions[session_id]
        pane_id = self._new_id("pane")
        tab_id = self._new_id("tab")
        terminal_id = self._new_id("term")
        self.panes[pane_id] = {
            "id": pane_id,
            "screen_id": screen["id"],
            "name": None,
            "focused": False,
            "zoomed": False,
        }
        self._add_terminal(
            tab_id,
            terminal_id,
            pane_id,
            None,
            params.get("cwd"),
        )
        self.revisions[session_id] += 1
        self._emit_delta(state, session_id, previous, [])
        result = self._mutation_result(
            self._terminal_path(
                screen["workspace_id"],
                screen["id"],
                pane_id,
                tab_id,
                terminal_id,
            ),
            session_id,
        )
        self._record_creation(
            request,
            operation,
            params,
            result["value"],
            session_id,
        )
        if indeterminate_after_apply:
            self._indeterminate(state, request, operation)
            return
        self._finish_mutation(state, request, operation, params, result)

    def _create_terminal_tab(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        params: Mapping[str, Any],
    ) -> None:
        operation = "tab.create_terminal"
        if self._replay_if_known(state, request, operation, params):
            return
        session_id = self._resolve_session(params.get("session"))
        if not self._expected_revision(state, request, params, session_id):
            return
        pane = self.panes[str(params["pane"])]
        screen = self.screens[pane["screen_id"]]
        previous = self.revisions[session_id]
        tab_id = self._new_id("tab")
        terminal_id = self._new_id("term")
        self._add_terminal(
            tab_id,
            terminal_id,
            pane["id"],
            params.get("name"),
            params.get("cwd"),
        )
        self.revisions[session_id] += 1
        self._emit_delta(state, session_id, previous, [])
        result = self._mutation_result(
            self._terminal_path(
                screen["workspace_id"],
                screen["id"],
                pane["id"],
                tab_id,
                terminal_id,
            ),
            session_id,
        )
        self._record_creation(
            request,
            operation,
            params,
            result["value"],
            session_id,
        )
        self._finish_mutation(state, request, operation, params, result)

    def _run_in_pane(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        params: Mapping[str, Any],
    ) -> None:
        operation = "pane.run"
        if self._replay_if_known(state, request, operation, params):
            return
        session_id = self._resolve_session(params.get("session"))
        if not self._expected_revision(state, request, params, session_id):
            return
        argv = params.get("argv")
        if not isinstance(argv, list) or not all(
            isinstance(item, str) for item in argv
        ):
            raise ValueError("pane.run requires exact argv in this fake")
        pane = self.panes[str(params["pane"])]
        screen = self.screens[pane["screen_id"]]
        previous = self.revisions[session_id]
        tab_id = self._new_id("tab")
        terminal_id = self._new_id("term")
        self._add_terminal(
            tab_id,
            terminal_id,
            pane["id"],
            params.get("name"),
            params.get("cwd"),
        )
        self.terminal_output[terminal_id] = self._output_for_argv(argv)
        self.revisions[session_id] += 1
        self._emit_delta(state, session_id, previous, [])
        result = self._mutation_result(
            self._terminal_path(
                screen["workspace_id"],
                screen["id"],
                pane["id"],
                tab_id,
                terminal_id,
            ),
            session_id,
        )
        self._record_creation(
            request,
            operation,
            params,
            result["value"],
            session_id,
        )
        self._finish_mutation(state, request, operation, params, result)
        self._mark_terminal_exited(state, session_id, terminal_id, 0)

    @staticmethod
    def _output_for_argv(argv: Sequence[str]) -> str:
        script = argv[-1] if argv else ""
        for marker in ("CMUX_SETUP_READY", "CMUX_BUILD_OK", "CMUX_TESTS_OK"):
            if marker in script:
                return "$ " + " ".join(argv[:2]) + "\n" + marker + "\n"
        return "$ " + " ".join(argv) + "\n"

    def _add_terminal(
        self,
        tab_id: str,
        terminal_id: str,
        pane_id: str,
        name: Any,
        cwd: Any,
    ) -> None:
        index = sum(1 for tab in self.tabs.values() if tab["pane_id"] == pane_id)
        self.tabs[tab_id] = {
            "id": tab_id,
            "pane_id": pane_id,
            "name": name if isinstance(name, str) else None,
            "index": index,
            "focused": False,
            "content_kind": "terminal",
            "content_id": terminal_id,
        }
        terminal = {
            "id": terminal_id,
            "tab_ids": [tab_id],
            "title": name if isinstance(name, str) else "",
            "cols": 100,
            "rows": 30,
            "running": True,
            "lifecycle": "running",
        }
        if isinstance(cwd, str):
            terminal["cwd"] = cwd
        self.terminals[terminal_id] = terminal
        self.terminal_output.setdefault(terminal_id, "$ \n")

    @staticmethod
    def _terminal_path(
        workspace_id: str,
        screen_id: str,
        pane_id: str,
        tab_id: str,
        terminal_id: str,
    ) -> dict:
        return {
            "kind": "terminal",
            "workspace_id": workspace_id,
            "screen_id": screen_id,
            "pane_id": pane_id,
            "tab_id": tab_id,
            "terminal_id": terminal_id,
        }

    def _wait_terminal(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        params: Mapping[str, Any],
    ) -> None:
        terminal_id = str(params["terminal"])
        output = self.terminal_output[terminal_id]
        pattern = params.get("pattern")
        if not isinstance(pattern, str):
            raise ValueError("terminal.wait omitted pattern")
        self._ok(
            state,
            request,
            {
                "matched": re.search(pattern, output) is not None,
                "text": output,
            },
        )

    def _mark_terminal_exited(
        self,
        state: _ConnectionState,
        session_id: str,
        terminal_id: str,
        exit_code: int,
    ) -> None:
        previous = self.revisions[session_id]
        self.revisions[session_id] += 1
        terminal = self.terminals[terminal_id]
        terminal["running"] = False
        terminal["lifecycle"] = "exited"
        terminal["exit"] = {
            "outcome": {"kind": "exit", "code": exit_code},
            "exited_at": "1700000000000",
            "revision": str(self.revisions[session_id]),
        }
        self._emit_delta(
            state,
            session_id,
            previous,
            [
                {
                    "kind": "upsert",
                    "sequence": 0,
                    "resource": "terminal",
                    "id": terminal_id,
                    "value": copy.deepcopy(terminal),
                }
            ],
        )

    def _wait_terminal_exit(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        params: Mapping[str, Any],
    ) -> None:
        terminal_id = str(params["terminal"])
        terminal = self.terminals[terminal_id]
        if terminal["lifecycle"] != "exited":
            self._ok(
                state,
                request,
                {
                    "state": "pending",
                    "terminal_id": terminal_id,
                    "lifecycle": terminal["lifecycle"],
                    "revision": str(
                        self.revisions[self._session_for_terminal(terminal_id)]
                    ),
                },
            )
            return
        exit_record = terminal["exit"]
        self._ok(
            state,
            request,
            {
                "state": "exited",
                "terminal_id": terminal_id,
                "lifecycle": "exited",
                "outcome": copy.deepcopy(exit_record["outcome"]),
                "exited_at": exit_record["exited_at"],
                "revision": exit_record["revision"],
            },
        )

    def _session_for_terminal(self, terminal_id: str) -> str:
        tab = self.tabs[self.terminals[terminal_id]["tab_ids"][0]]
        pane = self.panes[tab["pane_id"]]
        screen = self.screens[pane["screen_id"]]
        workspace_id = screen["workspace_id"]
        for session_id, workspaces in self.workspaces.items():
            if any(item["id"] == workspace_id for item in workspaces):
                return session_id
        raise ValueError(f"terminal {terminal_id} has no session")

    def _close_workspace(
        self,
        state: _ConnectionState,
        request: Mapping[str, Any],
        params: Mapping[str, Any],
    ) -> None:
        operation = "workspace.close"
        if self._replay_if_known(state, request, operation, params):
            return
        session_id = self._resolve_session(params.get("session"))
        if not self._expected_revision(state, request, params, session_id):
            return
        workspace = self._workspace(params.get("workspace"), session_id)
        outcome = self.workspace_close_indeterminate
        if outcome is not None and operation not in self._indeterminate_sent:
            self._indeterminate_sent.add(operation)
            if outcome == "applied":
                self._apply_workspace_close(state, session_id, workspace)
            self._indeterminate(state, request, operation)
            return

        self._apply_workspace_close(state, session_id, workspace)
        result = self._mutation_result({}, session_id)
        self._finish_mutation(state, request, operation, params, result)

    def _apply_workspace_close(
        self,
        state: _ConnectionState,
        session_id: str,
        workspace: Mapping[str, Any],
    ) -> None:
        previous = self.revisions[session_id]
        workspace_id = str(workspace["id"])
        self.workspaces[session_id] = [
            item
            for item in self.workspaces[session_id]
            if item["id"] != workspace_id
        ]
        screen_ids = [
            screen_id
            for screen_id, screen in self.screens.items()
            if screen["workspace_id"] == workspace_id
        ]
        pane_ids = [
            pane_id
            for pane_id, pane in self.panes.items()
            if pane["screen_id"] in screen_ids
        ]
        tab_ids = [
            tab_id
            for tab_id, tab in self.tabs.items()
            if tab["pane_id"] in pane_ids
        ]
        terminal_ids = [
            terminal_id
            for terminal_id, terminal in self.terminals.items()
            if any(tab_id in tab_ids for tab_id in terminal["tab_ids"])
        ]
        for mapping, ids in (
            (self.screens, screen_ids),
            (self.panes, pane_ids),
            (self.tabs, tab_ids),
            (self.terminals, terminal_ids),
            (self.terminal_output, terminal_ids),
        ):
            for resource_id in ids:
                mapping.pop(resource_id, None)
        self.revisions[session_id] += 1
        self._emit_delta(
            state,
            session_id,
            previous,
            [
                {
                    "kind": "delete",
                    "sequence": 0,
                    "resource": "workspace",
                    "id": workspace_id,
                }
            ],
        )

    def close(self) -> None:
        self._stop.set()
        try:
            self._listener.close()
        except OSError:
            pass
        with self._lock:
            connections = list(self._connections)
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                connection.close()
            except OSError:
                pass
        self._accept_thread.join(timeout=1.0)
        with self._lock:
            threads = list(self._threads)
        for thread in threads:
            thread.join(timeout=1.0)
        shutil.rmtree(self._root, ignore_errors=True)

    def __enter__(self) -> "FakeCmuxServer":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()
