from __future__ import annotations

from typing import Any, Mapping, Optional


class CmuxError(Exception):
    """Base class for cmux SDK failures."""


class CommandError(CmuxError):
    def __init__(
        self,
        message: str,
        response: Optional[Mapping[str, Any]] = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.response = response


class AuthorityError(CmuxError):
    """A command requires an authority the client did not explicitly enable."""

    def __init__(self, command: str, authority: str) -> None:
        super().__init__(
            f"{command} requires {authority}; "
            "construct CmuxClient with allow_provider_authority=True"
        )
        self.command = command
        self.authority = authority


class CmuxConnectionError(CmuxError):
    """The session socket could not be opened or stopped carrying frames."""


class ProtocolError(CmuxError):
    """A frame or typed value violated the negotiated protocol."""


class TimeoutError(CmuxError):
    """The server did not produce the next frame before the deadline."""


__all__ = [
    "CmuxError",
    "AuthorityError",
    "CommandError",
    "CmuxConnectionError",
    "ProtocolError",
    "TimeoutError",
]
