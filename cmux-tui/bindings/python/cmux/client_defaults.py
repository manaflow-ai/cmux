from __future__ import annotations

import os
import hashlib
import unicodedata
from typing import Optional


def default_socket_path(session: str = "main") -> str:
    validate_session_name(session)
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        runtime = os.environ.get("TMPDIR") or "/tmp"
    directory = f"cmux-tui-{os.getuid()}"
    preferred = os.path.join(runtime, directory, f"{session}.sock")
    capacity = 104 if os.uname().sysname == "Darwin" else 108
    if len(os.fsencode(preferred)) < capacity:
        return preferred
    digest = hashlib.sha256(session.encode("utf-8")).hexdigest()
    return os.path.join("/tmp", directory, f"{digest}.sock")


def validate_session_name(session: str) -> None:
    if not session or session in (".", ".."):
        raise ValueError("session name must be a non-empty path component without separators or control characters")
    if "\x00" in session or not session.isprintable():
        raise ValueError("session name must be a non-empty path component without separators or control characters")
    for character in session:
        if character in "/\\" or unicodedata.category(character).startswith("C") or character in "\u0085\u2028\u2029":
            raise ValueError("session name must be a non-empty path component without separators or control characters")


def env_socket_path() -> Optional[str]:
    return os.environ.get("CMUX_TUI_SOCKET") or os.environ.get("CMUX_MUX_SOCKET")


__all__ = ["default_socket_path", "env_socket_path", "validate_session_name"]
