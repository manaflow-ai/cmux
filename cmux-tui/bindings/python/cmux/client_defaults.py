from __future__ import annotations

import os
from typing import Optional


def default_socket_path(session: str = "main") -> str:
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        runtime = os.environ.get("TMPDIR") or "/tmp"
    return os.path.join(runtime, f"cmux-tui-{os.getuid()}", f"{session}.sock")


def env_socket_path() -> Optional[str]:
    return os.environ.get("CMUX_TUI_SOCKET") or os.environ.get("CMUX_MUX_SOCKET")


__all__ = ["default_socket_path", "env_socket_path"]
