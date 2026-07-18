from __future__ import annotations

import base64
import json
import os
import socket
import sys
import threading
from dataclasses import dataclass
from typing import Any, Dict, Iterator, List, Optional, cast
from uuid import UUID

from .topology import (
    TOPOLOGY_V8_CAPABILITIES,
    TopologyCursor,
    TopologyDelta,
    TopologyResnapshotRequired,
    TopologySnapshot,
    TopologySubscribed,
    parse_resnapshot_required,
    parse_topology_delta,
    parse_topology_snapshot,
    parse_topology_subscribed,
    validate_topology_delta,
)


class CmuxError(Exception):
    pass


class CommandError(CmuxError):
    def __init__(self, message: str, response: Optional[Dict[str, Any]] = None):
        super().__init__(message)
        self.message = message
        self.response = response


class CmuxConnectionError(CmuxError):
    pass


class ProtocolError(CmuxError):
    pass


class TimeoutError(CmuxError):
    pass


@dataclass(frozen=True)
class EmptyResult:
    pass


@dataclass(frozen=True)
class ResizeSurfaceResult:
    accepted: bool
    reservation_id: Optional[int] = None


@dataclass(frozen=True)
class ProcessInfoResult:
    pid: Optional[int]
    command: Optional[List[str]]
    cwd: Optional[str]
    tty: Optional[str]


@dataclass(frozen=True)
class EnsureTerminalEnvironment:
    name: str
    value: str


@dataclass(frozen=True)
class EnsureTerminalResult:
    created: bool
    workspace: int
    workspace_uuid: UUID
    screen: int
    screen_uuid: UUID
    pane: int
    pane_uuid: UUID
    surface: int
    surface_uuid: UUID


@dataclass(frozen=True)
class ReparentTerminalResult:
    moved: bool
    workspace: int
    workspace_uuid: UUID
    screen: int
    screen_uuid: UUID
    pane: int
    pane_uuid: UUID
    surface: int
    surface_uuid: UUID


@dataclass(frozen=True)
class IdentifyResult:
    app: str
    version: str
    protocol: int
    protocol_min: Optional[int]
    protocol_max: Optional[int]
    capabilities: List[str]
    session: str
    session_id: Optional[UUID]
    daemon_instance_id: Optional[UUID]
    topology_revision: Optional[int]
    canonical_topology_revision: Optional[int]
    pid: int

    @property
    def supports_topology_v8(self) -> bool:
        return self.protocol >= 8 and all(
            capability in self.capabilities for capability in TOPOLOGY_V8_CAPABILITIES
        )

    @property
    def topology_cursor(self) -> Optional[TopologyCursor]:
        if (
            self.daemon_instance_id is None
            or self.session_id is None
            or self.canonical_topology_revision is None
        ):
            return None
        return TopologyCursor(
            self.daemon_instance_id,
            self.session_id,
            self.canonical_topology_revision,
        )


@dataclass(frozen=True)
class PingResult:
    ok: bool
    version: str
    protocol: int
    protocol_min: Optional[int]
    protocol_max: Optional[int]
    capabilities: List[str]
    session: Optional[str]
    session_id: Optional[UUID]
    daemon_instance_id: Optional[UUID]
    topology_revision: Optional[int]
    canonical_topology_revision: Optional[int]
    pid: Optional[int]


@dataclass(frozen=True)
class ReloadConfigResult:
    reloaded: bool
    path: Optional[str]


@dataclass(frozen=True)
class SurfaceResult:
    surface: int


@dataclass(frozen=True)
class ReadScreenResult:
    text: str


@dataclass(frozen=True)
class VtStateResult:
    cols: int
    rows: int
    data: str

    @property
    def replay_bytes(self) -> bytes:
        return base64.b64decode(self.data)


@dataclass(frozen=True)
class Size:
    cols: int
    rows: int


@dataclass(frozen=True)
class Layout:
    type: str
    pane: Optional[int] = None
    dir: Optional[str] = None
    ratio: Optional[float] = None
    a: Optional["Layout"] = None
    b: Optional["Layout"] = None


@dataclass(frozen=True)
class Tab:
    surface: int
    kind: str
    browser_source: Optional[str]
    name: Optional[str]
    title: str
    size: Optional[Size]
    dead: bool


@dataclass(frozen=True)
class Pane:
    id: int
    name: Optional[str]
    active_tab: int
    tabs: List[Tab]
    dead: bool = False


@dataclass(frozen=True)
class Screen:
    id: int
    name: Optional[str]
    active: bool
    active_pane: int
    layout: Layout
    panes: List[Pane]


@dataclass(frozen=True)
class Workspace:
    id: int
    name: str
    active: bool
    screens: List[Screen]


@dataclass(frozen=True)
class Tree:
    workspaces: List[Workspace]


@dataclass(frozen=True)
class Event:
    event: str
    raw: Dict[str, Any]
    surface: Optional[int] = None
    cols: Optional[int] = None
    rows: Optional[int] = None
    data: Optional[str] = None
    replay: Optional[str] = None
    offset: Optional[int] = None
    at_bottom: Optional[bool] = None
    title: Optional[str] = None
    scope: Optional[str] = None
    error: Optional[str] = None
    retry_after_ms: Optional[int] = None
    reservation_id: Optional[int] = None

    @property
    def bytes_data(self) -> Optional[bytes]:
        payload = self.data if self.data is not None else self.replay
        return base64.b64decode(payload) if payload is not None else None


class _JsonLineConnection:
    def __init__(self, path: str, timeout: float):
        self.path = path
        self.timeout = timeout
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        try:
            self.sock.connect(path)
        except OSError as exc:
            self.sock.close()
            raise CmuxConnectionError(f"cannot connect to session socket {path}: {exc}") from exc
        self.reader = self.sock.makefile("r", encoding="utf-8", newline="\n")
        self._lock = threading.Lock()

    def send(self, value: Dict[str, Any]) -> None:
        line = json.dumps(value, separators=(",", ":")).encode("utf-8") + b"\n"
        with self._lock:
            try:
                self.sock.sendall(line)
            except OSError as exc:
                raise CmuxConnectionError(f"socket write failed: {exc}") from exc

    def recv(self) -> Dict[str, Any]:
        try:
            line = self.reader.readline()
        except socket.timeout as exc:
            raise TimeoutError("session did not respond") from exc
        except OSError as exc:
            raise CmuxConnectionError(f"socket read failed: {exc}") from exc
        if line == "":
            raise CmuxConnectionError("session socket closed")
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            raise ProtocolError(f"bad JSON from server: {exc}") from exc

    def close(self) -> None:
        try:
            self.reader.close()
        finally:
            self.sock.close()


class _Stream:
    def __init__(self, client: "CmuxClient", request: Dict[str, Any]):
        self._client = client
        self._conn = _JsonLineConnection(client.socket_path, client.timeout)
        self._queue: List[Any] = []
        self._closed = False
        self.response: Optional[Dict[str, Any]] = None
        request = dict(request)
        if "id" not in request:
            request["id"] = client._next_id()
        request_id = request["id"]
        self._conn.send(request)
        while True:
            value = self._conn.recv()
            if "event" in value:
                self._queue.append(self._parse(value))
                continue
            if value.get("id") != request_id:
                continue
            if value.get("ok") is True:
                self.response = value
                break
            raise CommandError(value.get("error", "unknown error"), value)

    def __iter__(self) -> "_Stream":
        return self

    def __next__(self) -> Event:
        if self._closed:
            raise StopIteration
        if self._queue:
            event = self._queue.pop(0)
            if self._terminal(event):
                self.close()
            return event
        value = self._conn.recv()
        if "event" not in value:
            return self.__next__()
        event = self._parse(value)
        if self._terminal(event):
            self.close()
        return event

    def _parse(self, value: Dict[str, Any]) -> Any:
        return _parse_event(value)

    def _terminal(self, event: Any) -> bool:
        return event.event in ("detached", "overflow")

    def close(self) -> None:
        if not self._closed:
            self._closed = True
            self._conn.close()


class EventStream(_Stream):
    pass


class AttachStream(_Stream):
    pass


class TopologyStream(_Stream):
    def __init__(self, client: "CmuxClient", cursor: TopologyCursor):
        self.cursor = cursor
        super().__init__(
            client,
            {
                "cmd": "subscribe-topology",
                "daemon_instance_id": str(cursor.daemon_instance_id),
                "session_id": str(cursor.session_id),
                "revision": cursor.revision,
            },
        )

    def _parse(self, value: Dict[str, Any]) -> Any:
        event = value.get("event")
        if event == "topology-resnapshot-required":
            return parse_resnapshot_required(value)
        if event != "topology-delta":
            raise ProtocolError(f"unexpected topology stream event {event!r}")
        delta = parse_topology_delta(value)
        required = validate_topology_delta(self.cursor, delta)
        if required is not None:
            return required
        self.cursor = TopologyCursor(
            self.cursor.daemon_instance_id,
            self.cursor.session_id,
            delta.revision,
        )
        return delta

    def __iter__(self) -> "TopologyStream":
        return self

    def __next__(self) -> TopologyDelta | TopologyResnapshotRequired:
        return cast(TopologyDelta | TopologyResnapshotRequired, super().__next__())

    def _terminal(self, event: Any) -> bool:
        return isinstance(event, TopologyResnapshotRequired)


class CmuxClient:
    def __init__(
        self,
        socket_path: Optional[str] = None,
        session: str = "main",
        timeout: float = 10.0,
        allow_protocol_v6_attach: bool = False,
    ):
        self.socket_path = socket_path or env_socket_path() or default_socket_path(session)
        self.timeout = timeout
        self.allow_protocol_v6_attach = allow_protocol_v6_attach
        self._conn = _JsonLineConnection(self.socket_path, timeout)
        self._next_request_id = 1
        self._id_lock = threading.Lock()
        self._protocol: Optional[int] = None
        self._identity: Optional[IdentifyResult] = None

    def __enter__(self) -> "CmuxClient":
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        self.close()

    def close(self) -> None:
        self._conn.close()

    def _next_id(self) -> int:
        with self._id_lock:
            value = self._next_request_id
            self._next_request_id += 1
            return value

    def request(self, cmd: str, **params: Any) -> Dict[str, Any]:
        payload = {"id": self._next_id(), "cmd": cmd}
        payload.update({key: value for key, value in params.items() if value is not None})
        request_id = payload["id"]
        self._conn.send(payload)
        while True:
            response = self._conn.recv()
            if "event" in response:
                continue
            if response.get("id") not in (request_id, None):
                continue
            return response

    def _request(self, cmd: str, **params: Any) -> Dict[str, Any]:
        response = self.request(cmd, **params)
        if response.get("ok") is True:
            return response.get("data", {})
        raise CommandError(response.get("error", "unknown error"), response)

    def identify(self) -> IdentifyResult:
        data = self._request("identify")
        session_id = data.get("session_id")
        daemon_instance_id = data.get("daemon_instance_id")
        result = IdentifyResult(
            app=str(data["app"]),
            version=str(data["version"]),
            protocol=int(data["protocol"]),
            protocol_min=int(data["protocol_min"]) if data.get("protocol_min") is not None else None,
            protocol_max=int(data["protocol_max"]) if data.get("protocol_max") is not None else None,
            capabilities=[str(value) for value in data.get("capabilities", [])],
            session=str(data["session"]),
            session_id=UUID(session_id) if session_id is not None else None,
            daemon_instance_id=UUID(daemon_instance_id) if daemon_instance_id is not None else None,
            topology_revision=(
                int(data["topology_revision"])
                if data.get("topology_revision") is not None
                else None
            ),
            canonical_topology_revision=(
                int(data["canonical_topology_revision"])
                if data.get("canonical_topology_revision") is not None
                else None
            ),
            pid=int(data["pid"]),
        )
        self._protocol = result.protocol
        self._identity = result
        return result

    def topology_snapshot(self) -> TopologySnapshot:
        self._require_topology_v8()
        try:
            return parse_topology_snapshot(self._request("topology-snapshot"))
        except (KeyError, TypeError, ValueError) as exc:
            raise ProtocolError(f"invalid topology snapshot: {exc}") from exc

    def subscribe_topology(
        self,
        cursor: TopologyCursor,
    ) -> TopologyStream | TopologyResnapshotRequired:
        self._require_topology_v8()
        try:
            stream = TopologyStream(self, cursor)
            assert stream.response is not None
            data = stream.response.get("data", {})
            status = data.get("status")
            if status == "resnapshot-required":
                required = parse_resnapshot_required(data)
                stream.close()
                return required
            if status != "subscribed":
                stream.close()
                raise ProtocolError(f"invalid subscribe-topology status {status!r}")
            info = parse_topology_subscribed(data)
            if (
                info.daemon_instance_id != cursor.daemon_instance_id
                or info.session_id != cursor.session_id
                or info.from_revision != cursor.revision
            ):
                stream.close()
                reason = (
                    "stale-daemon"
                    if info.daemon_instance_id != cursor.daemon_instance_id
                    else "stale-session"
                    if info.session_id != cursor.session_id
                    else "history-gap"
                )
                return parse_resnapshot_required(
                    {
                        "daemon_instance_id": str(info.daemon_instance_id),
                        "session_id": str(info.session_id),
                        "current_revision": info.current_revision,
                        "reason": reason,
                    }
                )
            stream.info = info
            return stream
        except (KeyError, TypeError, ValueError) as exc:
            raise ProtocolError(f"invalid topology subscription response: {exc}") from exc

    def _require_topology_v8(self) -> IdentifyResult:
        identity = self._identity or self.identify()
        if not identity.supports_topology_v8:
            missing = [
                capability
                for capability in TOPOLOGY_V8_CAPABILITIES
                if capability not in identity.capabilities
            ]
            raise ProtocolError(
                "canonical topology requires protocol 8 and capabilities "
                f"{','.join(TOPOLOGY_V8_CAPABILITIES)}; "
                f"server protocol={identity.protocol} missing={','.join(missing)}"
            )
        if identity.topology_cursor is None:
            raise ProtocolError("canonical topology identify response omitted its authority cursor")
        return identity

    def ping(self) -> PingResult:
        data = self._request("ping")
        session_id = data.get("session_id")
        daemon_instance_id = data.get("daemon_instance_id")
        return PingResult(
            ok=bool(data["ok"]),
            version=str(data["version"]),
            protocol=int(data["protocol"]),
            protocol_min=(
                int(data["protocol_min"])
                if data.get("protocol_min") is not None
                else None
            ),
            protocol_max=(
                int(data["protocol_max"])
                if data.get("protocol_max") is not None
                else None
            ),
            capabilities=[str(value) for value in data.get("capabilities", [])],
            session=str(data["session"]) if data.get("session") is not None else None,
            session_id=UUID(session_id) if session_id is not None else None,
            daemon_instance_id=(
                UUID(daemon_instance_id) if daemon_instance_id is not None else None
            ),
            topology_revision=(
                int(data["topology_revision"])
                if data.get("topology_revision") is not None
                else None
            ),
            canonical_topology_revision=(
                int(data["canonical_topology_revision"])
                if data.get("canonical_topology_revision") is not None
                else None
            ),
            pid=int(data["pid"]) if data.get("pid") is not None else None,
        )

    def reload_config(self) -> ReloadConfigResult:
        data = self._request("reload-config")
        return ReloadConfigResult(
            reloaded=bool(data.get("reloaded", False)),
            path=data.get("path"),
        )

    def list_workspaces(self) -> Tree:
        return _parse_tree(self._request("list-workspaces"))

    def export_layout(self, screen: Optional[int] = None) -> Dict[str, Any]:
        return self._request("export-layout", screen=screen)

    def apply_layout(
        self,
        layout: Dict[str, Any],
        workspace: Optional[int] = None,
        name: Optional[str] = None,
    ) -> Dict[str, Any]:
        return self._request("apply-layout", workspace=workspace, name=name, layout=layout)

    def send(
        self,
        surface: int,
        text: Optional[str] = None,
        bytes_data: Optional[bytes | str] = None,
    ) -> EmptyResult:
        encoded: Optional[str]
        if isinstance(bytes_data, bytes):
            encoded = base64.b64encode(bytes_data).decode("ascii")
        else:
            encoded = bytes_data
        self._request("send", surface=surface, text=text, bytes=encoded)
        return EmptyResult()

    def read_screen(self, surface: int) -> ReadScreenResult:
        data = self._request("read-screen", surface=surface)
        return ReadScreenResult(text=str(data["text"]))

    def vt_state(self, surface: int) -> VtStateResult:
        data = self._request("vt-state", surface=surface)
        return VtStateResult(cols=int(data["cols"]), rows=int(data["rows"]), data=str(data["data"]))

    def new_tab(
        self,
        pane: Optional[int] = None,
        cwd: Optional[str] = None,
        cols: Optional[int] = None,
        rows: Optional[int] = None,
    ) -> SurfaceResult:
        return SurfaceResult(int(self._request("new-tab", pane=pane, cwd=cwd, cols=cols, rows=rows)["surface"]))

    def new_browser_tab(
        self,
        url: str,
        pane: Optional[int] = None,
        cols: Optional[int] = None,
        rows: Optional[int] = None,
    ) -> SurfaceResult:
        return SurfaceResult(int(self._request("new-browser-tab", url=url, pane=pane, cols=cols, rows=rows)["surface"]))

    def new_workspace(
        self,
        name: Optional[str] = None,
        cols: Optional[int] = None,
        rows: Optional[int] = None,
    ) -> SurfaceResult:
        return SurfaceResult(int(self._request("new-workspace", name=name, cols=cols, rows=rows)["surface"]))

    def new_screen(
        self,
        workspace: Optional[int] = None,
        cols: Optional[int] = None,
        rows: Optional[int] = None,
    ) -> SurfaceResult:
        return SurfaceResult(int(self._request("new-screen", workspace=workspace, cols=cols, rows=rows)["surface"]))

    def split(
        self,
        pane: int,
        dir: str,
        cols: Optional[int] = None,
        rows: Optional[int] = None,
    ) -> SurfaceResult:
        return SurfaceResult(int(self._request("split", pane=pane, dir=dir, cols=cols, rows=rows)["surface"]))

    def set_ratio(self, pane: int, dir: str, ratio: float) -> EmptyResult:
        self._request("set-ratio", pane=pane, dir=dir, ratio=ratio)
        return EmptyResult()

    def pane_neighbor(self, pane: int, dir: str) -> Dict[str, Any]:
        return self._request("pane-neighbor", pane=pane, dir=dir)

    def focus_direction(self, dir: str, pane: Optional[int] = None) -> Dict[str, Any]:
        return self._request("focus-direction", pane=pane, dir=dir)

    def swap_pane(
        self,
        pane: int,
        dir: Optional[str] = None,
        target: Optional[int] = None,
    ) -> EmptyResult:
        self._request("swap-pane", pane=pane, dir=dir, target=target)
        return EmptyResult()

    def zoom_pane(self, pane: Optional[int] = None, mode: Optional[str] = None) -> Dict[str, Any]:
        return self._request("zoom-pane", pane=pane, mode=mode)

    def process_info(self, surface: int) -> ProcessInfoResult:
        data = self._request("process-info", surface=surface)
        command = data.get("command")
        if command is not None and (
            not isinstance(command, list)
            or any(not isinstance(argument, str) for argument in command)
        ):
            raise ProtocolError("process-info command must be an argv array or null")
        return ProcessInfoResult(
            pid=int(data["pid"]) if data.get("pid") is not None else None,
            command=command,
            cwd=str(data["cwd"]) if data.get("cwd") is not None else None,
            tty=str(data["tty"]) if data.get("tty") is not None else None,
        )

    def ensure_terminal(
        self,
        workspace_uuid: UUID,
        surface_uuid: UUID,
        cols: int,
        rows: int,
        *,
        cwd: Optional[str] = None,
        argv: Optional[List[str]] = None,
        command: Optional[str] = None,
        env: Optional[List[EnsureTerminalEnvironment]] = None,
        initial_input: Optional[str] = None,
        wait_after_command: bool = False,
    ) -> EnsureTerminalResult:
        if argv is not None and command is not None:
            raise ValueError("ensure-terminal argv and command are mutually exclusive")
        data = self._request(
            "ensure-terminal",
            workspace_uuid=str(workspace_uuid),
            surface_uuid=str(surface_uuid),
            cwd=cwd,
            argv=argv,
            command=command,
            env=(
                [{"name": entry.name, "value": entry.value} for entry in env]
                if env is not None
                else None
            ),
            initial_input=initial_input,
            wait_after_command=wait_after_command,
            cols=cols,
            rows=rows,
        )
        return EnsureTerminalResult(
            created=bool(data["created"]),
            workspace=int(data["workspace"]),
            workspace_uuid=UUID(str(data["workspace_uuid"])),
            screen=int(data["screen"]),
            screen_uuid=UUID(str(data["screen_uuid"])),
            pane=int(data["pane"]),
            pane_uuid=UUID(str(data["pane_uuid"])),
            surface=int(data["surface"]),
            surface_uuid=UUID(str(data["surface_uuid"])),
        )

    def reparent_terminal(
        self,
        surface_uuid: UUID,
        workspace_uuid: UUID,
    ) -> ReparentTerminalResult:
        data = self._request(
            "reparent-terminal",
            surface_uuid=str(surface_uuid),
            workspace_uuid=str(workspace_uuid),
        )
        return ReparentTerminalResult(
            moved=bool(data["moved"]),
            workspace=int(data["workspace"]),
            workspace_uuid=UUID(str(data["workspace_uuid"])),
            screen=int(data["screen"]),
            screen_uuid=UUID(str(data["screen_uuid"])),
            pane=int(data["pane"]),
            pane_uuid=UUID(str(data["pane_uuid"])),
            surface=int(data["surface"]),
            surface_uuid=UUID(str(data["surface_uuid"])),
        )

    def set_default_colors(self, fg: Optional[str] = None, bg: Optional[str] = None) -> EmptyResult:
        self._request("set-default-colors", fg=fg, bg=bg)
        return EmptyResult()

    def set_window_title(self, title: str) -> EmptyResult:
        self._request("set-window-title", title=title)
        return EmptyResult()

    def clear_window_title(self) -> EmptyResult:
        self._request("clear-window-title")
        return EmptyResult()

    def close_surface(self, surface: int) -> EmptyResult:
        self._request("close-surface", surface=surface)
        return EmptyResult()

    def close_pane(self, pane: int) -> EmptyResult:
        self._request("close-pane", pane=pane)
        return EmptyResult()

    def close_screen(self, screen: int) -> EmptyResult:
        self._request("close-screen", screen=screen)
        return EmptyResult()

    def close_workspace(self, workspace: int) -> EmptyResult:
        self._request("close-workspace", workspace=workspace)
        return EmptyResult()

    def rename_pane(self, pane: int, name: str) -> EmptyResult:
        self._request("rename-pane", pane=pane, name=name)
        return EmptyResult()

    def rename_surface(self, surface: int, name: str) -> EmptyResult:
        self._request("rename-surface", surface=surface, name=name)
        return EmptyResult()

    def rename_screen(self, screen: int, name: str) -> EmptyResult:
        self._request("rename-screen", screen=screen, name=name)
        return EmptyResult()

    def rename_workspace(self, workspace: int, name: str) -> EmptyResult:
        self._request("rename-workspace", workspace=workspace, name=name)
        return EmptyResult()

    def resize_surface(self, surface: int, cols: int, rows: int) -> ResizeSurfaceResult:
        data = self._request("resize-surface", surface=surface, cols=cols, rows=rows)
        return ResizeSurfaceResult(
            accepted=bool(data.get("accepted", True)),
            reservation_id=data.get("reservation_id"),
        )

    def focus_pane(self, pane: int) -> EmptyResult:
        self._request("focus-pane", pane=pane)
        return EmptyResult()

    def select_tab(
        self,
        pane: Optional[int] = None,
        index: Optional[int] = None,
        delta: Optional[int] = None,
    ) -> EmptyResult:
        self._request("select-tab", pane=pane, index=index, delta=delta)
        return EmptyResult()

    def select_screen(self, index: Optional[int] = None, delta: Optional[int] = None) -> EmptyResult:
        self._request("select-screen", index=index, delta=delta)
        return EmptyResult()

    def select_workspace(self, index: Optional[int] = None, delta: Optional[int] = None) -> EmptyResult:
        self._request("select-workspace", index=index, delta=delta)
        return EmptyResult()

    def move_tab(self, surface: int, pane: int, index: int) -> EmptyResult:
        self._request("move-tab", surface=surface, pane=pane, index=index)
        return EmptyResult()

    def move_workspace(self, workspace: int, index: int) -> EmptyResult:
        self._request("move-workspace", workspace=workspace, index=index)
        return EmptyResult()

    def scroll_surface(self, surface: int, delta: int) -> EmptyResult:
        self._request("scroll-surface", surface=surface, delta=delta)
        return EmptyResult()

    def subscribe(self) -> EventStream:
        return EventStream(self, {"cmd": "subscribe"})

    def subscribe_with_request(self, request: Dict[str, Any]) -> EventStream:
        return EventStream(self, request)

    def attach_surface(self, surface: int) -> AttachStream:
        protocol = self._protocol if self._protocol is not None else self.identify().protocol
        if protocol > 8:
            raise ProtocolError(f"unsupported protocol {protocol}; maximum supported is 8")
        if protocol > 5 and not self.allow_protocol_v6_attach:
            raise ProtocolError("protocol v6 attach streams require resized replay handling")
        return AttachStream(self, {"cmd": "attach-surface", "surface": surface})


def default_socket_path(session: str) -> str:
    base = _first_nonempty(os.environ.get("XDG_RUNTIME_DIR"), os.environ.get("TMPDIR")) or "/tmp"
    return _default_socket_path(base, str(os.getuid()), session, sys.platform == "darwin")


def _first_nonempty(*values: Optional[str]) -> Optional[str]:
    return next((value for value in values if value), None)


def _default_socket_path(base: str, uid: str, session: str, darwin: bool) -> str:
    candidate = os.path.join(base, f"cmux-tui-{uid}", f"{session}.sock")
    if darwin and len(os.fsencode(candidate)) > 103:
        return os.path.join("/tmp", f"cmux-tui-{uid}", f"{session}.sock")
    return candidate


def env_socket_path() -> Optional[str]:
    return os.environ.get("CMUX_TUI_SOCKET") or os.environ.get("CMUX_MUX_SOCKET")


def _parse_tree(data: Dict[str, Any]) -> Tree:
    return Tree(workspaces=[_parse_workspace(item) for item in data.get("workspaces", [])])


def _parse_workspace(value: Dict[str, Any]) -> Workspace:
    return Workspace(
        id=int(value.get("id", 0)),
        name=str(value.get("name", "")),
        active=bool(value.get("active", False)),
        screens=[_parse_screen(item) for item in value.get("screens", [])],
    )


def _parse_screen(value: Dict[str, Any]) -> Screen:
    return Screen(
        id=int(value.get("id", 0)),
        name=value.get("name"),
        active=bool(value.get("active", False)),
        active_pane=int(value.get("active_pane", 0)),
        layout=_parse_layout(value.get("layout", {"type": "leaf", "pane": 0})),
        panes=[_parse_pane(item) for item in value.get("panes", [])],
    )


def _parse_layout(value: Dict[str, Any]) -> Layout:
    if value.get("type") == "split":
        return Layout(
            type="split",
            dir=value.get("dir"),
            ratio=float(value.get("ratio", 0.0)),
            a=_parse_layout(value.get("a", {})),
            b=_parse_layout(value.get("b", {})),
        )
    return Layout(type="leaf", pane=int(value.get("pane", 0)))


def _parse_pane(value: Dict[str, Any]) -> Pane:
    if value.get("dead") is True and "tabs" not in value:
        return Pane(id=int(value.get("id", 0)), name=None, active_tab=0, tabs=[], dead=True)
    return Pane(
        id=int(value.get("id", 0)),
        name=value.get("name"),
        active_tab=int(value.get("active_tab", 0)),
        tabs=[_parse_tab(item) for item in value.get("tabs", [])],
        dead=bool(value.get("dead", False)),
    )


def _parse_tab(value: Dict[str, Any]) -> Tab:
    size_value = value.get("size")
    size = None
    if isinstance(size_value, dict):
        size = Size(cols=int(size_value.get("cols", 0)), rows=int(size_value.get("rows", 0)))
    return Tab(
        surface=int(value.get("surface", 0)),
        kind=str(value.get("kind", "pty")),
        browser_source=value.get("browser_source"),
        name=value.get("name"),
        title=str(value.get("title", "")),
        size=size,
        dead=bool(value.get("dead", False)),
    )


def _parse_event(value: Dict[str, Any]) -> Event:
    return Event(
        event=str(value.get("event", "")),
        raw=value,
        surface=value.get("surface"),
        cols=value.get("cols"),
        rows=value.get("rows"),
        data=value.get("data"),
        replay=value.get("replay"),
        offset=value.get("offset"),
        at_bottom=value.get("at_bottom"),
        title=value.get("title"),
        scope=value.get("scope"),
        error=value.get("error"),
        retry_after_ms=value.get("retry_after_ms"),
        reservation_id=value.get("reservation_id"),
    )
