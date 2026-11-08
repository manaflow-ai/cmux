#!/usr/bin/env python3
"""Protocol-10 conformance adapter for the public Python SDK."""

from __future__ import annotations

import dataclasses
import json
import sys
import threading
import time
from enum import Enum
from pathlib import Path
from typing import Any, Mapping


ROOT = Path(__file__).resolve().parents[6]
sys.path.insert(0, str(ROOT / "cmux-tui" / "bindings" / "python"))

from cmux import raw as cmux  # noqa: E402


UINT64_KEYS = {
    "client",
    "index",
    "offset",
    "pane",
    "pane_revision",
    "projection_revision",
    "request",
    "screen",
    "seq",
    "surface",
    "terminal_revision",
    "timeout_ms",
    "workspace",
    "workspace_revision",
}


def normalize(value: Any, key: str | None = None) -> Any:
    if value is cmux.MISSING:
        return None
    if isinstance(value, Enum):
        return value.value
    if dataclasses.is_dataclass(value):
        return normalize(dataclasses.asdict(value))
    if isinstance(value, Mapping):
        return {
            str(item_key): normalize(item_value, str(item_key))
            for item_key, item_value in value.items()
            if item_value is not cmux.MISSING and item_key != "raw"
        }
    if isinstance(value, (list, tuple)):
        return [normalize(item) for item in value]
    if isinstance(value, bytes):
        import base64

        return base64.b64encode(value).decode("ascii")
    if isinstance(value, int) and not isinstance(value, bool) and (
        key in UINT64_KEYS or (key is not None and key.endswith("_revision"))
    ):
        return str(value)
    return value


def event_value(event: Any) -> dict[str, Any]:
    raw = dict(getattr(event, "raw", {}) or {})
    if isinstance(event, cmux.UnknownEvent):
        return {
            "event": event.event,
            "unknown": True,
            "raw": normalize(event.raw),
        }
    if raw:
        return normalize(raw)
    return normalize(event)


def classify(error: BaseException) -> str:
    text = str(error).lower()
    if isinstance(error, cmux.TimeoutError) or "timed out" in text or "did not respond" in text:
        return "timeout"
    if "limit" in text or "exceed" in text or "too many" in text:
        return "limit"
    if isinstance(error, cmux.CommandError):
        return "command"
    if isinstance(error, cmux.ProtocolError):
        return "decode"
    return "transport"


def metadata() -> dict[str, Any]:
    commands = [
        {
            "name": item.wire_name,
            "authority": item.authority,
            "stream": item.stream_kind,
        }
        for item in cmux.COMMANDS.values()
    ]
    events = [
        {
            "name": item.wire_name,
            "streams": list(item.streams),
        }
        for item in cmux.EVENTS.values()
    ]
    return {"commands": commands, "events": events}


def make_client(
    request: Mapping[str, Any],
    *,
    allow_provider_authority: bool = False,
) -> cmux.CmuxClient:
    return cmux.CmuxClient(
        socket_path=str(request["socket_path"]),
        timeout=max(float(request.get("timeout_ms", 1000)) / 1000, 0.001),
        max_line_bytes=int(request.get("max_frame_bytes", 16 * 1024 * 1024)),
        max_pre_ack_events=int(request.get("max_buffered_events", 256)),
        allow_provider_authority=allow_provider_authority,
    )


def identify(request: Mapping[str, Any]) -> dict[str, Any]:
    with make_client(request) as client:
        value = client.identify()
        return {
            "app": value.app,
            "protocol": value.protocol,
            "workspace_revision": str(value.workspace_revision),
            "terminal_revision": str(value.terminal_revision),
        }


def nullable_literal(request: Mapping[str, Any]) -> dict[str, Any]:
    with make_client(request) as client:
        placement = client.create_terminal(key="workspace-key")
        return {"lifecycle": placement.lifecycle}


def optional_non_null_response(request: Mapping[str, Any]) -> dict[str, Any]:
    with make_client(request) as client:
        value = client.identify()
        return {"present": value.capabilities is not cmux.MISSING}


def optional_nullable_request(request: Mapping[str, Any]) -> dict[str, Any]:
    presence = str(request["presence"])
    with make_client(request) as client:
        if presence == "omitted":
            client.set_client_info()
        elif presence == "null":
            client.set_client_info(name=None)
        elif presence == "value":
            client.set_client_info(name="conformance-client")
        else:
            raise ValueError(f"unknown presence {presence!r}")
    return {"presence": presence}


def open_stream(client: cmux.CmuxClient, request: Mapping[str, Any]) -> Any:
    kind = request["stream"]
    if kind == "subscribe-coarse":
        return client.subscribe()
    if kind == "subscribe-deltas":
        return client.subscribe_deltas()
    surface = int(str(request.get("surface", "7")))
    if kind == "attach-byte":
        return client.attach_bytes(surface)
    if kind == "attach-render":
        return client.attach_render(surface)
    if kind == "attach-browser":
        return client.attach_browser(surface)
    raise ValueError(f"unknown stream {kind!r}")


def stream(request: Mapping[str, Any]) -> dict[str, Any]:
    client = make_client(request)
    events: list[dict[str, Any]] = []
    terminal = False
    try:
        opened = open_stream(client, request)
        try:
            for _ in range(int(request.get("events", 1))):
                try:
                    event = next(opened)
                except StopIteration:
                    terminal = True
                    break
                events.append(event_value(event))
                if getattr(event, "event", None) in ("overflow", "detached"):
                    terminal = True
        finally:
            opened.close()
    finally:
        client.close()
    return {"events": events, "terminal": terminal}


def required_nullable_event(request: Mapping[str, Any]) -> dict[str, Any]:
    client = make_client(request)
    opened = client.subscribe()
    try:
        event = next(opened)
        if not isinstance(event, cmux.ClientChangedEvent):
            raise cmux.ProtocolError(
                f"expected client-changed event, got {getattr(event, 'event', None)!r}"
            )
        return {"name": event.name}
    finally:
        opened.close()
        client.close()


def optional_non_null_event(request: Mapping[str, Any]) -> dict[str, Any]:
    client = make_client(request)
    opened = open_stream(client, request)
    try:
        event = next(opened)
        if not isinstance(event, cmux.OutputEvent):
            raise cmux.ProtocolError(
                f"expected output event, got {getattr(event, 'event', None)!r}"
            )
        return {"present": event.colors is not cmux.MISSING}
    finally:
        opened.close()
        client.close()


def close_pending_stream(request: Mapping[str, Any]) -> dict[str, Any]:
    client = make_client(request)
    opened = open_stream(client, request)
    finished = threading.Event()

    def read() -> None:
        try:
            next(opened)
        except BaseException:
            pass
        finally:
            finished.set()

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    time.sleep(int(request.get("close_after_ms", 50)) / 1000)
    opened.close()
    deadline = int(request.get("deadline_ms", 1000)) / 1000
    unblocked = finished.wait(deadline)
    client.close()
    reader.join(timeout=0.1)
    return {"unblocked": unblocked}


def authority(request: Mapping[str, Any]) -> dict[str, Any]:
    authority_name = str(request["authority"])
    with make_client(
        request,
        allow_provider_authority=authority_name == "provider-authority",
    ) as client:
        if authority_name == "control":
            client.ping()
            command = "ping"
        elif authority_name == "frontend":
            client.browser_back(7)
            command = "browser-back"
        elif authority_name == "local-admin":
            client.pairing_response(1, False)
            command = "pairing-response"
        elif authority_name == "provider-authority":
            client.mark_workspaces_provider_managed("conformance-authority")
            command = "mark-workspaces-provider-managed"
        else:
            raise ValueError(f"unknown authority {authority_name!r}")
    return {"command": command}


def authority_denied(request: Mapping[str, Any]) -> dict[str, Any]:
    with make_client(request) as client:
        try:
            client.mark_workspaces_provider_managed("conformance-authority")
        except cmux.AuthorityError:
            return {"denied": True}
    raise RuntimeError("default client allowed provider-authority command")


def real_flow(request: Mapping[str, Any]) -> dict[str, Any]:
    marker = str(request.get("marker", "cmux-sdk-conformance-marker"))
    workspace_name = str(request.get("workspace_name", "sdk-conformance-workspace"))
    renamed_name = str(request.get("renamed_name", "sdk-conformance-renamed"))
    client = make_client(request)
    opened = None
    workspace: int | None = None
    closed = False
    try:
        identity = client.identify()
        opened = client.subscribe_deltas()
        created = client.new_workspace(name=workspace_name, cols=80, rows=24)
        surface = created.surface
        client.send(surface, text=f"printf '{marker}\\n'\r")
        waited = client.wait_for(surface, marker, 5_000)
        screen = client.read_screen(surface)
        context = cmux.find_surface(client.list_workspaces(), surface)
        if context is None:
            raise RuntimeError(f"created surface {surface} is absent from the tree")
        workspace = context.workspace.id
        terminal_created = context.tab.kind == "pty" and not context.tab.dead
        renamed = client.rename_workspace(renamed_name, workspace=workspace)
        client.close_workspace(workspace=workspace)
        closed = True
        remaining = client.list_workspaces()
        disappeared = all(item.id != workspace for item in remaining.workspaces)

        required_events = [
            "workspace-added",
            "workspace-renamed",
            "workspace-closed",
        ]
        observed: list[str] = []
        for _ in range(64):
            if all(name in observed for name in required_events):
                break
            observed.append(next(opened).event)
        positions = [observed.index(name) for name in required_events]
        stream_ordered = positions == sorted(positions)
        return {
            "identified": identity.protocol == 12,
            "workspace_created": workspace > 0,
            "terminal_created": terminal_created,
            "marker_sent": True,
            "wait_matched": waited.matched is True,
            "read_contains_marker": marker in screen.text,
            "stream_ordered": stream_ordered,
            "renamed": renamed.workspace == workspace,
            "closed": closed,
            "disappeared": disappeared,
            "observed_events": observed,
        }
    finally:
        if workspace is not None and not closed:
            try:
                client.close_workspace(workspace=workspace)
            except BaseException:
                pass
        if opened is not None:
            opened.close()
        client.close()


def dispatch(request: Mapping[str, Any]) -> Any:
    operation = request.get("op")
    if operation == "metadata":
        return metadata()
    if operation == "identify":
        return identify(request)
    if operation == "nullable-literal":
        return nullable_literal(request)
    if operation == "optional-non-null-response":
        return optional_non_null_response(request)
    if operation == "optional-nullable-request":
        return optional_nullable_request(request)
    if operation == "stream":
        return stream(request)
    if operation == "required-nullable-event":
        return required_nullable_event(request)
    if operation == "optional-non-null-event":
        return optional_non_null_event(request)
    if operation == "close-pending-stream":
        return close_pending_stream(request)
    if operation == "authority":
        return authority(request)
    if operation == "authority-denied":
        return authority_denied(request)
    if operation == "real-flow":
        return real_flow(request)
    raise ValueError(f"unknown adapter operation {operation!r}")


def main() -> int:
    line = sys.stdin.buffer.readline()
    request: dict[str, Any] = json.loads(line)
    response: dict[str, Any] = {
        "contract_version": 1,
        "id": request.get("id"),
    }
    try:
        response["value"] = dispatch(request)
        response["ok"] = True
    except BaseException as error:
        response["ok"] = False
        response["error"] = {"kind": classify(error), "message": str(error)}
    sys.stdout.write(json.dumps(response, separators=(",", ":"), ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
