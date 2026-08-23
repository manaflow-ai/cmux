from __future__ import annotations

import hashlib
import os
import sys
from typing import Optional


def _unix_socket_path_fits(path: str) -> bool:
    capacity = 104 if sys.platform == "darwin" else 108
    return len(os.fsencode(path)) < capacity


def _runtime_base() -> str:
    return (
        os.environ.get("XDG_RUNTIME_DIR")
        or os.environ.get("TMPDIR")
        or "/tmp"
    )


def _hashed_session_socket_path(session: str, base: str) -> str:
    digest = hashlib.sha256(session.encode("utf-8")).hexdigest()
    return os.path.join(base, f"cmux-tui-hashed-{os.getuid()}", f"{digest}.sock")


def validate_session_name(session: str) -> None:
    """Reject session text that cannot be one safe socket path component."""
    invalid = (
        not session
        or session in {".", ".."}
        or any(
            character in {"/", "\\", "\x00"}
            or ord(character) < 0x20
            or 0x7F <= ord(character) <= 0x9F
            or character in {"\u0085", "\u2028", "\u2029"}
            or 0xD800 <= ord(character) <= 0xDFFF
            for character in session
        )
    )
    if invalid:
        raise ValueError(
            "session name must be a non-empty path component "
            "without separators or control characters"
        )


def default_socket_path(session: str = "main") -> str:
    """Return the default socket path after validating the session name."""
    validate_session_name(session)
    runtime = _runtime_base()
    file_name = f"{session}.sock"
    preferred = os.path.join(runtime, f"cmux-tui-{os.getuid()}", file_name)
    if _unix_socket_path_fits(preferred):
        return preferred
    fallback = os.path.join("/tmp", f"cmux-tui-{os.getuid()}", file_name)
    if _unix_socket_path_fits(fallback):
        return fallback
    hashed = _hashed_session_socket_path(session, runtime)
    if _unix_socket_path_fits(hashed):
        return hashed
    hashed = _hashed_session_socket_path(session, "/tmp")
    if not _unix_socket_path_fits(hashed):
        raise ValueError("derived Unix socket path is too long")
    return hashed


def env_socket_path() -> Optional[str]:
    return os.environ.get("CMUX_TUI_SOCKET") or os.environ.get("CMUX_MUX_SOCKET") or None


__all__ = ["default_socket_path", "env_socket_path", "validate_session_name"]
