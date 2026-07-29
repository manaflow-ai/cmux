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


def live_session(client: cmux.Client):
    return client.session(cmux.Selector.current())


def workspace_rows(current: Any) -> dict[str, str]:
    rows: dict[str, str] = {}
    for item in current.list_workspaces():
        snapshot = item.snapshot
        if snapshot is None:
            snapshot = item.refresh()
        rows[str(snapshot.id)] = snapshot.name
    return rows


def live_setup(
    client: cmux.Client,
    base_name: str,
    key_prefix: str,
) -> dict[str, Any]:
    current = live_session(client)
    pinged = bool(plain(current.ping())["alive"])
    stable = current.create_workspace(
        cmux.CreateWorkspaceOptions(
            name=base_name,
            initial_content="empty",
        ),
        idempotency_key=f"{key_prefix}-stable-create",
    ).value.workspace
    if stable is None or stable.id is None:
        raise AssertionError("workspace.create omitted stable workspace handle")
    stable_id = str(stable.id)
    stable_renamed_name = f"{base_name}-renamed"
    renamed = stable.rename(
        stable_renamed_name,
        idempotency_key=f"{key_prefix}-stable-rename",
    )
    renamed_snapshot = renamed.value.snapshot
    if renamed_snapshot is None:
        renamed_snapshot = renamed.value.refresh()

    duplicate_name = f"{base_name}-duplicate"
    duplicate_ids: list[str] = []
    for suffix in ("a", "b"):
        duplicate = current.create_workspace(
            cmux.CreateWorkspaceOptions(
                name=duplicate_name,
                initial_content="empty",
            ),
            idempotency_key=f"{key_prefix}-duplicate-{suffix}",
        ).value.workspace
        if duplicate is None or duplicate.id is None:
            raise AssertionError("workspace.create omitted duplicate workspace handle")
        duplicate_ids.append(str(duplicate.id))

    ambiguity_code = ""
    ambiguity_candidates: list[str] = []
    try:
        current.workspace(cmux.Selector.name(duplicate_name)).rename(
            f"{base_name}-must-not-apply",
            idempotency_key=f"{key_prefix}-ambiguous-rename",
        )
    except cmux.ResourceError as error:
        ambiguity_code = error.code
        details = plain(error.details)
        if isinstance(details, Mapping):
            candidates = details.get("candidates")
            if isinstance(candidates, list):
                ambiguity_candidates = [
                    str(candidate) for candidate in candidates
                ]
    else:
        raise AssertionError("duplicate workspace selector unexpectedly mutated")

    rows = workspace_rows(current)
    return {
        "pinged": pinged,
        "stable_id": stable_id,
        "stable_renamed": renamed_snapshot.name == stable_renamed_name,
        "duplicate_ids": duplicate_ids,
        "ambiguity_code": ambiguity_code,
        "ambiguity_preserved_all_candidates": (
            set(ambiguity_candidates) == set(duplicate_ids)
            and len(ambiguity_candidates) == len(duplicate_ids)
        ),
        "no_mutation": (
            all(rows.get(identifier) == duplicate_name for identifier in duplicate_ids)
            and f"{base_name}-must-not-apply" not in rows.values()
        ),
    }


def live_restart(
    client: cmux.Client,
    base_name: str,
    key_prefix: str,
    expected_stable_id: str,
    expected_duplicate_ids: list[str],
) -> dict[str, Any]:
    current = live_session(client)
    rows = workspace_rows(current)
    expected_ids = {expected_stable_id, *expected_duplicate_ids}
    same_ids = expected_ids.issubset(rows)
    stable_name_preserved = (
        rows.get(expected_stable_id) == f"{base_name}-renamed"
    )
    duplicates_preserved = all(
        rows.get(identifier) == f"{base_name}-duplicate"
        for identifier in expected_duplicate_ids
    )

    current.workspace(cmux.WorkspaceId(expected_stable_id)).close(
        idempotency_key=f"{key_prefix}-close-stable"
    )
    for suffix, identifier in zip(("a", "b"), expected_duplicate_ids):
        current.workspace(cmux.WorkspaceId(identifier)).close(
            idempotency_key=f"{key_prefix}-close-{suffix}"
        )
    remaining = workspace_rows(current)
    return {
        "same_ids": same_ids,
        "stable_name_preserved": stable_name_preserved,
        "duplicates_preserved": duplicates_preserved,
        "closed": True,
        "disappeared": expected_ids.isdisjoint(remaining),
    }


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
        if operation == "live-setup":
            return live_setup(
                client,
                str(payload["workspace_name"]),
                str(payload["key_prefix"]),
            )
        if operation == "live-restart":
            duplicate_ids = payload["expected_duplicate_ids"]
            if not isinstance(duplicate_ids, list) or not all(
                isinstance(identifier, str) for identifier in duplicate_ids
            ):
                raise TypeError("expected_duplicate_ids must be a string list")
            return live_restart(
                client,
                str(payload["workspace_name"]),
                str(payload["key_prefix"]),
                str(payload["expected_stable_id"]),
                duplicate_ids,
            )
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
