#!/usr/bin/env python3
"""Launch Codex with a content-free, process-bound Surface Status marker.

This is not a lifecycle hook. cmux's official persistent hooks remain the sole
source for Working, Needs Input, Error, and Idle. The marker only identifies a
Codex process during the pre-hook startup window.
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import stat
import sys
import tempfile
import time
import uuid


def is_cmux_shim(path: pathlib.Path, launcher: pathlib.Path) -> bool:
    resolved = path.resolve(strict=False)
    text = str(resolved)
    try:
        same_file = path.samefile(launcher)
    except OSError:
        same_file = False
    return (
        same_file
        or resolved == launcher
        or "/cmux-cli-shims/" in text
        or text.endswith("/cmux-codex-wrapper")
    )


def resolve_codex(launcher: pathlib.Path) -> pathlib.Path:
    candidates: list[pathlib.Path] = []
    explicit = os.environ.get("CMUX_SURFACE_STATUS_CODEX_REAL", "").strip()
    if explicit:
        candidates.append(pathlib.Path(explicit).expanduser())
    found = shutil.which("codex")
    if found:
        candidates.append(pathlib.Path(found))
    candidates.extend((
        pathlib.Path("/opt/homebrew/bin/codex"),
        pathlib.Path("/usr/local/bin/codex"),
    ))
    seen: set[str] = set()
    for candidate in candidates:
        resolved = candidate.resolve(strict=False)
        if str(resolved) in seen:
            continue
        seen.add(str(resolved))
        if (
            candidate.is_file()
            and os.access(candidate, os.X_OK)
            and not is_cmux_shim(candidate, launcher)
            and not is_cmux_shim(resolved, launcher)
        ):
            return resolved
    raise RuntimeError("real Codex executable not found outside cmux's shim")


def valid_uuid(value: str) -> str | None:
    try:
        return str(uuid.UUID(value)).upper()
    except (ValueError, AttributeError):
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


def main() -> int:
    launcher = pathlib.Path(__file__).resolve()
    try:
        codex = resolve_codex(launcher)
    except RuntimeError as error:
        print(f"codex: {error}", file=sys.stderr)
        return 127

    args = [str(codex), "-c", "suppress_unstable_features_warning=true", *sys.argv[1:]]
    env = dict(os.environ)
    env.pop("CMUX_CODEX_HOOKS_DISABLED", None)
    env["CMUX_CODEX_PID"] = str(os.getpid())
    env["CMUX_AGENT_LAUNCH_KIND"] = "codex"
    env["CMUX_AGENT_LAUNCH_EXECUTABLE"] = str(codex)
    env["CMUX_AGENT_LAUNCH_CWD"] = os.getcwd()

    surface_id = valid_uuid(env.get("CMUX_SURFACE_ID", ""))
    workspace_id = valid_uuid(env.get("CMUX_WORKSPACE_ID", ""))
    if surface_id is not None:
        publish_marker(pathlib.Path.home().resolve(), surface_id, workspace_id)

    os.execve(codex, args, env)
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
