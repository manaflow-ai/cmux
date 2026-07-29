from __future__ import annotations

from typing import Any, Literal, Mapping, Optional, TypedDict


class CmuxError(Exception):
    """Base class for cmux SDK failures."""


class ResourceError(CmuxError):
    """Structured error returned by a resource-protocol operation."""

    def __init__(
        self,
        code: str,
        message: str,
        details: Any,
        retryable: bool,
    ) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.details = details
        self.retryable = retryable


class MutationIndeterminateDetails(TypedDict):
    idempotency_key: str
    operation: str
    recovery: Literal["inspect_state_then_retry_with_new_key"]


class MutationIndeterminateError(ResourceError):
    """An external effect may have completed without a durable receipt."""

    code: Literal["mutation.indeterminate"]
    details: MutationIndeterminateDetails

    def __init__(
        self,
        message: str,
        details: MutationIndeterminateDetails,
    ) -> None:
        super().__init__("mutation.indeterminate", message, details, False)


class CommandError(CmuxError):
    """Legacy raw-protocol command failure."""

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


class StreamError(CmuxError):
    """A resource stream ended with an error or unrecoverable gap."""

    def __init__(
        self,
        reason: str,
        *,
        error: Optional[ResourceError] = None,
        recovery: Optional[str] = None,
    ) -> None:
        message = f"stream ended: {reason}"
        if error is not None:
            message = f"{message}: {error}"
        if recovery:
            message = f"{message} ({recovery})"
        super().__init__(message)
        self.reason = reason
        self.error = error
        self.recovery = recovery


__all__ = [
    "CmuxError",
    "MutationIndeterminateDetails",
    "MutationIndeterminateError",
    "ResourceError",
    "StreamError",
    "AuthorityError",
    "CommandError",
    "CmuxConnectionError",
    "ProtocolError",
    "TimeoutError",
]
