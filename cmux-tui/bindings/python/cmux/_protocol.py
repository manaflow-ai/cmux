from __future__ import annotations

import json
import math
import queue
import secrets
import threading
import time
from dataclasses import dataclass
from typing import (
    Any,
    Callable,
    Dict,
    Generic,
    Iterator,
    Mapping,
    Optional,
    Protocol,
    TypeVar,
)

from ._operations import Operations
from .errors import (
    CancelledError,
    CmuxConnectionError,
    ConfirmationRequiredDetails,
    ConfirmationRequiredError,
    MutationIndeterminateDetails,
    MutationIndeterminateError,
    ProtocolError,
    ResourceError,
    StreamError,
    TimeoutError,
)
from .ids import PaneId, StreamId
from .models import Cursor, StreamEnd, StreamItem
from .transport import JsonLineConnection


PROTOCOL = "cmux.protocol/1"
MAX_REQUEST_BYTES = 4 * 1024 * 1024
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
MAX_STREAM_MESSAGES = 256
MAX_STREAM_BYTES = 16 * 1024 * 1024
ItemT = TypeVar("ItemT")


def _is_unicode_whitespace(character: str) -> bool:
    codepoint = ord(character)
    return (
        0x0009 <= codepoint <= 0x000D
        or codepoint
        in (
            0x0020,
            0x0085,
            0x00A0,
            0x1680,
            0x2028,
            0x2029,
            0x202F,
            0x205F,
            0x3000,
        )
        or 0x2000 <= codepoint <= 0x200A
    )


def _is_unicode_control(character: str) -> bool:
    codepoint = ord(character)
    return codepoint <= 0x001F or 0x007F <= codepoint <= 0x009F


def _validate_idempotency_key(value: object) -> str:
    if not isinstance(value, str):
        raise TypeError("idempotency_key must be a string")
    try:
        byte_length = len(value.encode("utf-8"))
    except UnicodeEncodeError as error:
        raise ValueError("idempotency_key must contain valid Unicode scalars") from error
    if not 1 <= byte_length <= 128:
        raise ValueError("idempotency_key must contain 1 to 128 UTF-8 bytes")
    if all(_is_unicode_whitespace(character) for character in value):
        raise ValueError(
            "idempotency_key must contain at least one non-whitespace Unicode scalar"
        )
    if any(_is_unicode_control(character) for character in value):
        raise ValueError(
            "idempotency_key must not contain Unicode control characters"
        )
    return value


_END = object()


class _CancellationSignal(Protocol):
    def is_set(self) -> bool:
        ...


def _decimal(value: Any, label: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or any(character not in "0123456789" for character in value)
        or (len(value) > 1 and value.startswith("0"))
        or len(value) > 20
        or (
            len(value) == 20
            and value > "18446744073709551615"
        )
    ):
        raise TypeError(f"{label} must be a canonical uint64 decimal string")
    return value


@dataclass
class _Pending:
    event: threading.Event
    value: Optional[Mapping[str, Any]] = None
    error: Optional[BaseException] = None


@dataclass(frozen=True)
class _QueuedItem(Generic[ItemT]):
    value: StreamItem[ItemT]
    size: int


class _StreamState(Generic[ItemT]):
    def __init__(
        self,
        stream_id: StreamId,
        decode_item: Callable[[Any], ItemT],
        cancel_route: Mapping[str, str],
    ) -> None:
        self.stream_id = stream_id
        self.decode_item = decode_item
        self.cancel_route = dict(cancel_route)
        # The extra queue entry is reserved for the end-of-stream control message.
        self.values: "queue.Queue[object]" = queue.Queue(MAX_STREAM_MESSAGES + 1)
        self.end: Optional[StreamEnd] = None
        self.lock = threading.Lock()
        self.queued_messages = 0
        self.queued_bytes = 0

    def push(self, envelope: Mapping[str, Any]) -> bool:
        """Queues one item without blocking. Returns false after local overflow."""
        try:
            sequence = _decimal(envelope["sequence"], "sequence")
            cursor = _decode_cursor(envelope.get("cursor"))
            item = StreamItem(
                self.stream_id,
                sequence,
                self.decode_item(envelope.get("item")),
                cursor,
            )
        except (KeyError, TypeError, ValueError) as error:
            self.finish(
                StreamEnd(
                    self.stream_id,
                    "error",
                    error=ProtocolError(f"invalid stream item: {error}"),
                )
            )
            return True
        encoded_size = len(
            json.dumps(
                envelope,
                ensure_ascii=False,
                separators=(",", ":"),
                allow_nan=False,
            ).encode("utf-8")
        )
        with self.lock:
            if self.end is not None:
                return True
            if (
                self.queued_messages >= MAX_STREAM_MESSAGES
                or encoded_size > MAX_STREAM_BYTES - self.queued_bytes
            ):
                self._finish_locked(
                    StreamEnd(
                        self.stream_id,
                        "gap",
                        recovery="reopen the stream to obtain a fresh snapshot",
                    ),
                    purge=True,
                )
                return False
            self.values.put_nowait(_QueuedItem(item, encoded_size))
            self.queued_messages += 1
            self.queued_bytes += encoded_size
            return True

    def finish(self, end: StreamEnd, *, purge: bool = False) -> None:
        with self.lock:
            self._finish_locked(end, purge=purge)

    def consumed(self, size: int) -> None:
        with self.lock:
            self.queued_messages -= 1
            self.queued_bytes -= size

    def _finish_locked(self, end: StreamEnd, *, purge: bool) -> None:
        if self.end is not None:
            if purge:
                while True:
                    try:
                        self.values.get_nowait()
                    except queue.Empty:
                        break
                self.queued_messages = 0
                self.queued_bytes = 0
                self.values.put_nowait(_END)
            return
        if purge:
            while True:
                try:
                    self.values.get_nowait()
                except queue.Empty:
                    break
            self.queued_messages = 0
            self.queued_bytes = 0
        self.end = end
        self.values.put_nowait(_END)


class ProtocolConnection:
    """One multiplexed synchronous resource-protocol connection."""

    def __init__(self, socket_path: str, timeout: float) -> None:
        self.socket_path = socket_path
        self.timeout = timeout
        self._wire = JsonLineConnection(
            socket_path,
            timeout,
            max_line_bytes=MAX_RESPONSE_BYTES + 1,
        )
        # Per-request deadlines are enforced by Pending events. The one shared
        # reader must remain idle indefinitely between requests and events.
        self._wire.set_timeout(None)
        self._lock = threading.Lock()
        self._pending: Dict[str, _Pending] = {}
        self._streams: Dict[StreamId, _StreamState[Any]] = {}
        self._closed = False
        self._failure: Optional[BaseException] = None
        self._reader = threading.Thread(
            target=self._read_loop,
            name=f"cmux-resource-reader-{secrets.token_hex(4)}",
            daemon=True,
        )
        self._reader.start()

    @property
    def closed(self) -> bool:
        with self._lock:
            return self._closed

    def request(
        self,
        operation: str,
        params: Mapping[str, Any],
        *,
        idempotency_key: Optional[str] = None,
        timeout: Optional[float] = None,
        cancel_event: Optional[_CancellationSignal] = None,
    ) -> Any:
        if cancel_event is not None and cancel_event.is_set():
            raise CancelledError(operation, dispatched=False)
        wait_for = self.timeout if timeout is None else timeout
        if (
            isinstance(wait_for, bool)
            or not isinstance(wait_for, (int, float))
        ):
            raise TypeError("request timeout must be a number")
        if not math.isfinite(wait_for) or wait_for <= 0:
            raise ValueError(
                "request timeout must be finite and greater than zero"
            )
        request_id = f"request-{secrets.token_hex(16)}"
        envelope: Dict[str, Any] = {
            "protocol": PROTOCOL,
            "type": "request",
            "id": request_id,
            "operation": operation,
            "params": dict(params),
        }
        if idempotency_key is not None:
            envelope["idempotency_key"] = _validate_idempotency_key(idempotency_key)
        encoded = json.dumps(
            envelope,
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
        if len(encoded) > MAX_REQUEST_BYTES:
            raise ProtocolError(
                f"request exceeds {MAX_REQUEST_BYTES}-byte resource-protocol limit"
            )
        pending = _Pending(threading.Event())
        with self._lock:
            if self._closed:
                raise self._closed_error()
            self._pending[request_id] = pending
        deadline = time.monotonic() + wait_for
        try:
            self._wire.send(envelope)
        except BaseException:
            with self._lock:
                self._pending.pop(request_id, None)
            raise
        while not pending.event.is_set():
            if cancel_event is not None and cancel_event.is_set():
                with self._lock:
                    self._pending.pop(request_id, None)
                raise CancelledError(operation, dispatched=True)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                with self._lock:
                    self._pending.pop(request_id, None)
                raise TimeoutError(
                    f"{operation} did not respond before the deadline"
                )
            pending.event.wait(min(remaining, 0.01))
        if pending.error is not None:
            raise pending.error
        assert pending.value is not None
        return _decode_response(pending.value)

    def open_stream(
        self,
        operation: str,
        params: Mapping[str, Any],
        decode_item: Callable[[Any], ItemT],
        *,
        timeout: Optional[float] = None,
        cancel_event: Optional[_CancellationSignal] = None,
    ) -> "ResourceStream[ItemT]":
        stream_id = StreamId(f"stream_{secrets.token_hex(16)}")
        cancel_route = {
            key: str(params[key])
            for key in ("machine", "session")
            if key in params
        }
        if set(cancel_route) != {"machine", "session"}:
            raise ProtocolError(
                f"{operation} stream requires machine and session selectors"
            )
        state: _StreamState[ItemT] = _StreamState(
            stream_id,
            decode_item,
            cancel_route,
        )
        with self._lock:
            if self._closed:
                raise self._closed_error()
            self._streams[stream_id] = state
        stream_params = dict(params)
        stream_params["stream_id"] = str(stream_id)
        try:
            self.request(
                operation,
                stream_params,
                timeout=timeout,
                cancel_event=cancel_event,
            )
        except BaseException:
            with self._lock:
                self._streams.pop(stream_id, None)
            raise
        return ResourceStream(self, state)

    def cancel_stream(self, stream_id: StreamId) -> None:
        with self._lock:
            state = self._streams.get(stream_id)
            if state is None:
                return
        state.finish(
            StreamEnd(stream_id, "canceled"),
            purge=True,
        )
        self.forget_stream(stream_id)
        try:
            self.request(
                Operations.STREAM_CANCEL.wire_name,
                {
                    **state.cancel_route,
                    "stream": str(stream_id),
                },
                timeout=min(max(self.timeout, 0.1), 1.0),
            )
        except (CmuxConnectionError, TimeoutError):
            pass

    def forget_stream(self, stream_id: StreamId) -> None:
        with self._lock:
            self._streams.pop(stream_id, None)

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
            error = CmuxConnectionError("resource connection is closed")
            self._failure = error
            pending = tuple(self._pending.values())
            self._pending.clear()
            streams = tuple(self._streams.values())
            self._streams.clear()
        for item in pending:
            item.error = error
            item.event.set()
        for stream in streams:
            stream.finish(StreamEnd(stream.stream_id, "closed", error=error))
        self._wire.close()
        if threading.current_thread() is not self._reader:
            self._reader.join(timeout=max(self.timeout, 0.1) + 0.5)

    def _read_loop(self) -> None:
        try:
            while True:
                envelope = self._wire.recv()
                self._dispatch(envelope)
        except BaseException as error:
            self._fail(error)

    def _dispatch(self, envelope: Mapping[str, Any]) -> None:
        if envelope.get("protocol") != PROTOCOL:
            raise ProtocolError("server frame has the wrong protocol")
        envelope_type = envelope.get("type")
        if envelope_type == "response":
            request_id = envelope.get("id")
            if not isinstance(request_id, str):
                raise ProtocolError("response id must be a string")
            with self._lock:
                pending = self._pending.pop(request_id, None)
            if pending is not None:
                pending.value = envelope
                pending.event.set()
            return
        if envelope_type in {"stream_item", "stream_end"}:
            raw_stream_id = envelope.get("stream_id")
            try:
                stream_id = StreamId(raw_stream_id)
            except (TypeError, ValueError) as error:
                raise ProtocolError(f"invalid stream_id: {error}") from error
            with self._lock:
                stream = self._streams.get(stream_id)
            if stream is None:
                return
            if envelope_type == "stream_item":
                if not stream.push(envelope):
                    self.forget_stream(stream_id)
                    threading.Thread(
                        target=self._cancel_stream_best_effort,
                        args=(stream_id, stream.cancel_route),
                        name=f"cmux-stream-cancel-{secrets.token_hex(4)}",
                        daemon=True,
                    ).start()
                return
            end = _decode_stream_end(stream_id, envelope)
            stream.finish(end)
            self.forget_stream(stream_id)
            return
        raise ProtocolError(f"unknown resource envelope type {envelope_type!r}")

    def _fail(self, error: BaseException) -> None:
        if not isinstance(
            error,
            (CmuxConnectionError, ProtocolError, TimeoutError),
        ):
            error = CmuxConnectionError(str(error))
        with self._lock:
            if self._closed:
                return
            self._closed = True
            self._failure = error
            pending = tuple(self._pending.values())
            self._pending.clear()
            streams = tuple(self._streams.values())
            self._streams.clear()
        for item in pending:
            item.error = error
            item.event.set()
        for stream in streams:
            stream.finish(StreamEnd(stream.stream_id, "error", error=error))
        self._wire.close()

    def _closed_error(self) -> BaseException:
        return self._failure or CmuxConnectionError("resource connection is closed")

    def _cancel_stream_best_effort(
        self,
        stream_id: StreamId,
        cancel_route: Mapping[str, str],
    ) -> None:
        try:
            self.request(
                Operations.STREAM_CANCEL.wire_name,
                {
                    **cancel_route,
                    "stream": str(stream_id),
                },
                timeout=min(max(self.timeout, 0.1), 1.0),
            )
        except BaseException:
            pass


class ResourceStream(Generic[ItemT], Iterator[StreamItem[ItemT]]):
    """Typed, explicitly cancellable stream."""

    def __init__(
        self,
        connection: ProtocolConnection,
        state: _StreamState[ItemT],
    ) -> None:
        self._connection = connection
        self._state = state

    @property
    def id(self) -> StreamId:
        return self._state.stream_id

    @property
    def end(self) -> Optional[StreamEnd]:
        return self._state.end

    def __iter__(self) -> "ResourceStream[ItemT]":
        return self

    def __next__(self) -> StreamItem[ItemT]:
        return self.next()

    def next(self, timeout: Optional[float] = None) -> StreamItem[ItemT]:
        if timeout is not None and (
            isinstance(timeout, bool) or not isinstance(timeout, (int, float))
        ):
            raise TypeError("stream timeout must be a number")
        if timeout is not None and (
            not math.isfinite(timeout) or timeout <= 0
        ):
            raise ValueError("stream timeout must be finite and greater than zero")
        try:
            value = self._state.values.get(timeout=timeout)
        except queue.Empty as error:
            raise TimeoutError(
                "stream did not produce an item before the deadline"
            ) from error
        if value is _END:
            end = self._state.end
            if end is not None and end.reason in {"error", "gap"}:
                if isinstance(end.error, ResourceError):
                    raise StreamError(
                        end.reason,
                        error=end.error,
                        recovery=end.recovery,
                    )
                if end.error is not None:
                    raise end.error
                raise StreamError(end.reason, recovery=end.recovery)
            raise StopIteration
        queued = value
        assert isinstance(queued, _QueuedItem)
        self._state.consumed(queued.size)
        return queued.value

    def cancel(self) -> None:
        if self._state.end is not None:
            return
        self._connection.cancel_stream(self.id)

    def close(self) -> None:
        self.cancel()

    def __enter__(self) -> "ResourceStream[ItemT]":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.cancel()


def _decode_response(envelope: Mapping[str, Any]) -> Any:
    if envelope.get("ok") is True and "result" in envelope and "error" not in envelope:
        return envelope["result"]
    if envelope.get("ok") is False and "error" in envelope and "result" not in envelope:
        error = envelope["error"]
        if not isinstance(error, Mapping):
            raise ProtocolError("error response must contain an error object")
        raise _decode_resource_error(error)
    raise ProtocolError("response must contain exactly one result or error")


def _decode_cursor(value: Any) -> Optional[Cursor]:
    if value is None:
        return None
    if not isinstance(value, Mapping):
        raise TypeError("cursor must be an object")
    if set(value) != {"generation", "revision"}:
        raise TypeError("cursor must contain only generation and revision")
    generation = value.get("generation")
    revision = value.get("revision")
    if (
        not isinstance(generation, str)
        or not 1 <= len(generation) <= 128
    ):
        raise TypeError("cursor generation must contain 1 to 128 characters")
    return Cursor(generation, _decimal(revision, "cursor revision"))


def _decode_resource_error(error: Mapping[str, Any]) -> ResourceError:
    code = error.get("code")
    message = error.get("message")
    retryable = error.get("retryable")
    if (
        not isinstance(code, str)
        or not isinstance(message, str)
        or not isinstance(retryable, bool)
        or "details" not in error
    ):
        raise ProtocolError("error response has invalid structured fields")
    details = error["details"]
    if code == "confirmation.required":
        if (
            retryable
            or not isinstance(details, Mapping)
            or set(details)
            != {"confirmation_token", "revision", "closes_panes"}
        ):
            raise ProtocolError("confirmation.required has invalid details")
        token = details.get("confirmation_token")
        panes = details.get("closes_panes")
        if (
            not isinstance(token, str)
            or not token
            or len(token.encode("utf-8")) > 128
            or not isinstance(panes, list)
            or not panes
        ):
            raise ProtocolError("confirmation.required has invalid details")
        try:
            revision = _decimal(
                details.get("revision"),
                "confirmation.required revision",
            )
            closes_panes = tuple(PaneId(value) for value in panes)
        except (TypeError, ValueError) as error:
            raise ProtocolError(
                "confirmation.required has invalid details"
            ) from error
        return ConfirmationRequiredError(
            message,
            ConfirmationRequiredDetails(token, revision, closes_panes),
        )
    if code == "mutation.indeterminate":
        if (
            retryable
            or not isinstance(details, Mapping)
            or set(details) != {"idempotency_key", "operation", "recovery"}
            or not isinstance(details.get("idempotency_key"), str)
            or not isinstance(details.get("operation"), str)
            or details.get("recovery")
            != "inspect_state_then_retry_with_new_key"
        ):
            raise ProtocolError("mutation.indeterminate has invalid details")
        typed_details: MutationIndeterminateDetails = {
            "idempotency_key": details["idempotency_key"],
            "operation": details["operation"],
            "recovery": "inspect_state_then_retry_with_new_key",
        }
        return MutationIndeterminateError(message, typed_details)
    return ResourceError(code, message, details, retryable)


def _decode_stream_end(
    stream_id: StreamId,
    envelope: Mapping[str, Any],
) -> StreamEnd:
    reason = envelope.get("reason")
    if reason not in {"completed", "canceled", "closed", "gap", "error"}:
        raise ProtocolError("stream end has invalid reason")
    error_value = envelope.get("error")
    error: Optional[BaseException] = None
    if error_value is not None:
        if not isinstance(error_value, Mapping):
            raise ProtocolError("stream error must be an object")
        error = _decode_resource_error(error_value)
    recovery = envelope.get("recovery")
    if recovery is not None and not isinstance(recovery, str):
        raise ProtocolError("stream recovery must be a string")
    return StreamEnd(
        stream_id,
        reason,
        _decode_cursor(envelope.get("cursor")),
        error,
        recovery,
    )


__all__ = [
    "MAX_REQUEST_BYTES",
    "MAX_RESPONSE_BYTES",
    "MAX_STREAM_BYTES",
    "MAX_STREAM_MESSAGES",
    "PROTOCOL",
    "ProtocolConnection",
    "ResourceStream",
]
