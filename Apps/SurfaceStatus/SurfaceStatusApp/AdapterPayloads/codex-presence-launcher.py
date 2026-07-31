#!/usr/bin/env python3
"""Launch Codex with a content-free, process-bound Surface Status marker.

This is not a lifecycle hook. cmux's official wrapper and persistent hooks
remain the sole source for Working, Needs Input, Error, and Idle. The marker
only identifies a Codex process during the pre-hook startup window.
"""

from __future__ import annotations

import json
import os
import pathlib
import stat
import sys
import tempfile
import time
import uuid


def is_surface_status_launcher(path: pathlib.Path, launcher: pathlib.Path) -> bool:
    """Reject only recursion back into this helper, never cmux's wrapper."""
    try:
        return path.samefile(launcher)
    except OSError:
        try:
            return path.resolve(strict=False) == launcher.resolve(strict=False)
        except OSError:
            return False


def executable_candidate(value: str, launcher: pathlib.Path) -> pathlib.Path | None:
    try:
        candidate = pathlib.Path(value).expanduser()
        if (
            candidate.is_file()
            and os.access(candidate, os.X_OK)
            and not is_surface_status_launcher(candidate, launcher)
        ):
            return candidate.resolve(strict=False)
    except (OSError, RuntimeError):
        pass
    return None


def resolve_codex(launcher: pathlib.Path) -> pathlib.Path:
    candidates: list[str] = []

    # Preserve cmux's official invocation chain. Its per-surface shim delegates
    # to cmux-codex-wrapper, which owns hook injection and opt-out behavior.
    wrapper_shim = os.environ.get("CMUX_CODEX_WRAPPER_SHIM", "").strip()
    if wrapper_shim:
        candidates.append(wrapper_shim)

    explicit = os.environ.get("CMUX_SURFACE_STATUS_CODEX_REAL", "").strip()
    if explicit:
        candidates.append(explicit)

    candidates.extend(os.path.join(entry or os.curdir, "codex") for entry in os.get_exec_path())
    candidates.extend(("/opt/homebrew/bin/codex", "/usr/local/bin/codex"))

    seen: set[str] = set()
    for value in candidates:
        candidate = executable_candidate(value, launcher)
        if candidate is None:
            continue
        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)
        return candidate
    raise RuntimeError("Codex executable or cmux wrapper shim not found")


def valid_uuid(value: str) -> str | None:
    try:
        return str(uuid.UUID(value)).upper()
    except (ValueError, TypeError, AttributeError):
        return None


def safe_marker_directory(home: pathlib.Path) -> pathlib.Path | None:
    directory = home / ".cmuxterm"
    try:
        if directory.is_symlink():
            return None
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = directory.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            return None
        os.chmod(directory, 0o700)
        return directory
    except OSError:
        return None


def publish_marker(home: pathlib.Path, surface_id: str, workspace_id: str | None) -> None:
    directory = safe_marker_directory(home)
    if directory is None:
        return
    marker = directory / f"codex-{surface_id}-sidebar-agent-launch.json"
    payload: dict[str, object] = {
        "schemaVersion": 1,
        "kind": "codex-launch",
        "agentID": "codex",
        "surfaceID": surface_id,
        "pid": os.getpid(),
        "ownerToken": str(uuid.uuid4()).upper(),
        "createdAt": time.time(),
    }
    if workspace_id is not None:
        payload["workspaceID"] = workspace_id
    data = (json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n").encode()
    descriptor = -1
    temporary = ""
    try:
        descriptor, temporary = tempfile.mkstemp(prefix=f".{marker.name}.", suffix=".tmp", dir=directory)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            descriptor = -1
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, marker)
        temporary = ""
    except OSError:
        pass
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def enrich_and_publish_marker(env: dict[str, str]) -> None:
    """Best-effort telemetry; no failure here may block downstream Codex."""
    try:
        env["CMUX_CODEX_PID"] = str(os.getpid())
        env["CMUX_AGENT_LAUNCH_KIND"] = "codex"
        try:
            env["CMUX_AGENT_LAUNCH_CWD"] = os.getcwd()
        except OSError:
            pass

        if env.get("CMUX_CODEX_HOOKS_DISABLED") == "1":
            return
        surface_id = valid_uuid(env.get("CMUX_SURFACE_ID", ""))
        workspace_id = valid_uuid(env.get("CMUX_WORKSPACE_ID", ""))
        home_value = env.get("HOME", "")
        if surface_id is not None and home_value:
            publish_marker(pathlib.Path(home_value).expanduser(), surface_id, workspace_id)
    except (OSError, RuntimeError, ValueError):
        pass


def main() -> int:
    launcher = pathlib.Path(__file__).resolve(strict=False)
    try:
        downstream = resolve_codex(launcher)
    except RuntimeError as error:
        print(f"codex: {error}", file=sys.stderr)
        return 127

    # This helper is attribution-only: preserve argv and hook policy exactly.
    args = [str(downstream), *sys.argv[1:]]
    env = dict(os.environ)
    enrich_and_publish_marker(env)
    os.execve(downstream, args, env)
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
