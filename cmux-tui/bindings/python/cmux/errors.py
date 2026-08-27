from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Literal, Mapping, Optional, Tuple, TypedDict

from .ids import PaneId


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


@dataclass(frozen=True)
class ConfirmationRequiredDetails:
    confirmation_token: str
    revision: str
    closes_panes: Tuple[PaneId, ...]


class ConfirmationRequiredError(ResourceError):
    """A destructive layout mutation needs a fresh stale-state fence."""

    code: Literal["confirmation.required"]
    details: ConfirmationRequiredDetails

    def __init__(
        self,
        message: str,
        details: ConfirmationRequiredDetails,
    ) -> None:
        super().__init__("confirmation.required", message, details, False)


class MutationTransportError(CmuxError):
    """A mutation lost its response after transport failure.

    The mutation may have completed. Inspect current state before deciding
    whether to retry, and reuse ``idempotency_key`` for the same logical
    attempt.
    """

    def __init__(
        self,
        operation: str,
        idempotency_key: str,
        cause: CmuxError,
    ) -> None:
        super().__init__(
            f"{operation} transport failed after dispatch; mutation outcome is "
            f"uncertain (idempotency_key={idempotency_key})"
        )
        self.operation = operation
        self.idempotency_key = idempotency_key
        self.cause = cause


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


class CancelledError(CmuxError):
    """A local cancellation signal stopped a request."""

    def __init__(self, operation: str, *, dispatched: bool) -> None:
        when = "after dispatch" if dispatched else "before dispatch"
        super().__init__(f"{operation} was canceled {when}")
        self.operation = operation
        self.dispatched = dispatched


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
    "ConfirmationRequiredDetails",
    "ConfirmationRequiredError",
    "MutationIndeterminateDetails",
    "MutationIndeterminateError",
    "MutationTransportError",
    "ResourceError",
    "StreamError",
    "AuthorityError",
    "CommandError",
    "CancelledError",
    "CmuxConnectionError",
    "ProtocolError",
    "TimeoutError",
]
