from ._generated import *
from ._generated import __all__ as _generated_all
from .client import (
    AttachStream,
    CmuxClient,
    EventStream,
    MISSING,
    MissingType,
    default_socket_path,
    env_socket_path,
)
from .convenience import (
    SurfaceContext,
    active_live_pty,
    find_surface,
    render_row_text,
)
from .errors import (
    AuthorityError,
    CmuxConnectionError,
    CmuxError,
    CommandError,
    ProtocolError,
    TimeoutError,
)

__all__ = list(
    dict.fromkeys(
        (
            "AttachStream",
            "CmuxClient",
            "EventStream",
            "MISSING",
            "MissingType",
            "default_socket_path",
            "env_socket_path",
            "SurfaceContext",
            "active_live_pty",
            "find_surface",
            "render_row_text",
            "AuthorityError",
            "CmuxConnectionError",
            "CmuxError",
            "CommandError",
            "ProtocolError",
            "TimeoutError",
            *_generated_all,
        )
    )
)
