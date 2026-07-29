#!/usr/bin/env python3
"""Public resource conformance adapter for the dependency-free Python SDK."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Mapping


ROOT = Path(__file__).resolve().parents[5]
sys.path.insert(0, str(ROOT / "cmux-tui" / "bindings" / "python"))

import cmux  # noqa: E402


def error_value(error: cmux.ResourceError) -> dict[str, Any]:
    return {
        "code": error.code,
        "message": error.message,
        "details": plain(error.details),
        "retryable": error.retryable,
    }


def plain(value: Any) -> Any:
    if isinstance(value, cmux.Document):
        return plain(value.fields)
    if isinstance(value, cmux.Cursor):
        return {
            "generation": value.generation,
            "revision": str(value.revision),
        }
    if isinstance(value, Mapping):
        return {str(key): plain(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain(item) for item in value]
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    if hasattr(value, "value") and isinstance(value.value, str):
        return value.value
    return value


def session(client: cmux.Client, constants: Mapping[str, str]):
    return client.session(cmux.SessionId(constants["session"]))


def workspace(client: cmux.Client, constants: Mapping[str, str]):
    return session(client, constants).workspace(
        cmux.WorkspaceId(constants["workspace"])
    )


def mutation_value(result: Any) -> dict[str, Any]:
    handle = result.value
    snapshot = handle.snapshot
    if snapshot is None:
        snapshot = handle.refresh()
    return {
        "workspace_id": str(snapshot.id),
        "name": snapshot.name,
        "generation": result.generation,
        "revision": str(result.revision),
        "replayed": result.replayed,
    }


def unknown_value(item: Any) -> tuple[str, dict[str, Any]]:
    value = getattr(item, "value", getattr(item, "item", None))
    if not isinstance(value, cmux.Unknown):
        raise AssertionError("session event was not the public Unknown variant")
    return value.kind, plain(value.raw)


def drain_end(stream: Any) -> str:
    try:
        while True:
            next(stream)
    except cmux.StreamError as error:
        return error.reason
    except StopIteration:
        end = stream.end
        return end.reason if end is not None else "completed"


def run(payload: Mapping[str, Any]) -> Any:
    operation = payload["op"]
    constants = payload["constants"]
    if operation == "redaction":
        secret = "provider://conformance-secret"
        token = "renderer-conformance-secret"
        specifier = cmux.ExternalMachineSpecifier(secret)
        grant = cmux.RendererGrant(
            token,
            endpoint="unix:///tmp/renderer",
            terminal_id=cmux.TerminalId(
                "term_66666666666666666666666666666666"
            ),
            rights=("render",),
            ttl_ms=1000,
        )
        return {
            "specifier_redacted": secret not in repr(specifier)
            and secret not in str(specifier),
            "renderer_token_redacted": token not in repr(grant)
            and token not in str(grant),
        }

    with cmux.Client(
        payload["socket_path"],
        timeout=15.0,
        random_hex_128=lambda: "a" * 32,
    ) as client:
        if operation == "read":
            document = session(client, constants).ping()
            fields = plain(document)
            return {
                "alive": fields["alive"],
                "cursor": fields["cursor"],
            }
        if operation == "mutation-replay":
            target = workspace(client, constants)
            options = {
                "idempotency_key": constants["idempotency_key"],
                "expected_revision": constants["revision"],
            }
            first = target.rename(constants["name"], **options)
            second = target.rename(constants["name"], **options)
            return {
                "first": mutation_value(first),
                "second": mutation_value(second),
            }
        if operation == "mutation-error":
            try:
                workspace(client, constants).rename(
                    constants["name"],
                    idempotency_key=constants["idempotency_key"],
                    expected_revision=constants["revision"],
                )
            except cmux.ResourceError as error:
                return error_value(error)
            raise AssertionError("mutation unexpectedly succeeded")
        if operation == "stream-unknown":
            stream = session(client, constants).events()
            item = next(stream)
            kind, raw = unknown_value(item)
            try:
                next(stream)
            except StopIteration:
                pass
            return {
                "sequence": str(item.sequence),
                "cursor": plain(item.cursor),
                "kind": kind,
                "raw": raw,
                "end": stream.end.reason if stream.end else "completed",
            }
        if operation == "stream-cancel":
            stream = session(client, constants).events()
            stream.cancel()
            stream.cancel()
            count = 0
            try:
                while True:
                    next(stream)
                    count += 1
            except StopIteration:
                pass
            return {
                "end": stream.end.reason if stream.end else "canceled",
                "items_after_cancel": count,
                "cancel_calls": 2,
            }
        if operation == "stream-overflow":
            first = session(client, constants).events()
            first_end = drain_end(first)
            second = session(client, constants).events()
            second_item = next(second)
            second_kind, _ = unknown_value(second_item)
            try:
                next(second)
            except StopIteration:
                pass
            control = plain(session(client, constants).ping())
            return {
                "first_end": first_end,
                "second_kind": second_kind,
                "control_alive": control["alive"],
            }
        if operation == "live-flow":
            current = client.session(cmux.Selector.current())
            pinged = bool(plain(current.ping())["alive"])
            name = payload["workspace_name"]
            created = current.create_workspace(
                cmux.CreateWorkspaceOptions(name=name, initial_content="empty"),
                idempotency_key="live-create",
            )
            created_workspace = created.value.workspace
            if created_workspace is None:
                raise AssertionError("workspace.create omitted workspace handle")
            created_id = created_workspace.id
            renamed = created_workspace.rename(
                name + "-renamed", idempotency_key="live-rename"
            )
            listed = any(
                item.id == created_id
                for item in current.list_workspaces()
            )
            created_workspace.close(idempotency_key="live-close")
            disappeared = all(
                item.id != created_id
                for item in current.list_workspaces()
            )
            return {
                "pinged": pinged,
                "created": created_id is not None,
                "renamed": renamed.value.snapshot.name == name + "-renamed",
                "listed": listed,
                "closed": True,
                "disappeared": disappeared,
            }
    raise AssertionError(f"unknown adapter operation {operation}")


def main() -> int:
    payload = json.loads(sys.stdin.readline())
    identifier = payload.get("id")
    try:
        value = run(payload)
        response = {
            "contract_version": 2,
            "id": identifier,
            "ok": True,
            "value": value,
        }
    except BaseException as error:
        response = {
            "contract_version": 2,
            "id": identifier,
            "ok": False,
            "error": {
                "kind": "adapter",
                "message": f"{type(error).__name__}: {error}",
            },
        }
    print(json.dumps(response, separators=(",", ":"), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
