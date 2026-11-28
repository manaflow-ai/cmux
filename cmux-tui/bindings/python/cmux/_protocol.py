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


PROTOCOL = "cmux.protocol/2"
MAX_REQUEST_BYTES = 4 * 1024 * 1024
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
MAX_STREAM_MESSAGES = 256
MAX_STREAM_BYTES = 16 * 1024 * 1024
STREAM_CLEANUP_TIMEOUT = 1.0
REQUEST_CLEANUP_TIMEOUT = 1.0
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
_REQUEST_NOT_DISPATCHED = object()


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
    on_resource_error: Optional[Callable[[], None]] = None
    abandoned_result_decoder: Optional[Callable[[Any], Any]] = None
    abandoned_error: Optional[BaseException] = None
    response_received: bool = False
    cleanup_started: bool = False


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
        validate_item: Optional[
            Callable[[ItemT, Optional[Cursor]], None]
        ] = None,
    ) -> None:
        self.stream_id = stream_id
        self.attachment_lease: Optional[str] = None
        self.decode_item = decode_item
        self.validate_item = validate_item
        self.cancel_route = dict(cancel_route)
        # The extra queue entry is reserved for the end-of-stream control message.
        self.values: "queue.Queue[object]" = queue.Queue(MAX_STREAM_MESSAGES + 1)
        self.end: Optional[StreamEnd] = None
        self.lock = threading.Lock()
        self.queued_messages = 0
        self.queued_bytes = 0
        self.open_dispatched = False
        self.open_acknowledged = False
        self.open_rejected = False
        self.open_send_failed = False
        self.open_send_error: Optional[BaseException] = None
        self.cleanup_started = False
        self.cancel_dispatch_started = False
        self.explicit_cancel_started = False
        self.explicit_cancel_deadline: Optional[float] = None
        self.explicit_cancel_failure: Optional[BaseException] = None
        self.explicit_cancel_done = threading.Event()
        self.end_event = threading.Event()

    def mark_open_dispatched(self) -> None:
        with self.lock:
            self.open_dispatched = True

    def mark_open_acknowledged(self) -> None:
        with self.lock:
            self.open_acknowledged = True

    def mark_open_rejected(self) -> None:
        with self.lock:
            self.open_rejected = True

    def mark_open_send_failed(self, error: BaseException) -> None:
        with self.lock:
            self.open_send_failed = True
            self.open_send_error = error

    def begin_failed_open_cleanup(self) -> bool:
        with self.lock:
            if (
                not self.open_dispatched
                or self.open_acknowledged
                or self.open_rejected
                or self.cleanup_started
            ):
                return False
            self.cleanup_started = True
            return True

    def begin_stream_cleanup(self) -> bool:
        with self.lock:
            if not self.open_dispatched or self.cleanup_started:
                return False
            self.cleanup_started = True
            return True

    def begin_cancel_dispatch(self, *, failed_open: bool) -> bool:
        with self.lock:
            if self.cancel_dispatch_started or not self.open_dispatched:
                return False
            if failed_open and (
                self.open_acknowledged
                or self.open_rejected
                or self.open_send_failed
            ):
                return False
            self.cancel_dispatch_started = True
            return True

    def begin_explicit_cancel(
        self,
        deadline: float,
    ) -> tuple[str, Optional[BaseException], float]:
        with self.lock:
            if self.explicit_cancel_failure is not None:
                return "failed", self.explicit_cancel_failure, deadline
            if self.explicit_cancel_done.is_set():
                return "completed", None, deadline
            if self.explicit_cancel_started:
                assert self.explicit_cancel_deadline is not None
                return "waiting", None, self.explicit_cancel_deadline
            if self.end is not None:
                return "completed", None, deadline
            if self.cleanup_started:
                return "waiting", None, deadline
            self.cleanup_started = True
            self.explicit_cancel_started = True
            self.explicit_cancel_deadline = deadline
            while True:
                try:
                    self.values.get_nowait()
                except queue.Empty:
                    break
            self.queued_messages = 0
            self.queued_bytes = 0
            return "started", None, deadline

    def claim_explicit_cancel_failure(
        self,
        error: BaseException,
    ) -> tuple[BaseException, bool]:
        with self.lock:
            if self.explicit_cancel_failure is None:
                self.explicit_cancel_failure = error
                return error, True
            return self.explicit_cancel_failure, False

    def complete_explicit_cancel(self) -> None:
        with self.lock:
            self.explicit_cancel_done.set()

    def explicit_cancel_outcome(self) -> Optional[BaseException]:
        with self.lock:
            return self.explicit_cancel_failure

    def explicit_cancel_in_progress(self) -> bool:
        with self.lock:
            return (
                self.explicit_cancel_started
                and not self.explicit_cancel_done.is_set()
            )

    def push(
        self,
        envelope: Mapping[str, Any],
        sequence: str,
        cursor: Optional[Cursor],
        payload: Any,
    ) -> bool:
        """Queues one item without blocking. Returns false after local overflow."""
        try:
            decoded_item = self.decode_item(payload)
            if self.validate_item is not None:
                self.validate_item(decoded_item, cursor)
            item = StreamItem(
                self.stream_id,
                sequence,
                decoded_item,
                cursor,
            )
        except (KeyError, TypeError, ValueError, ProtocolError) as error:
            failure = ProtocolError(f"invalid stream item: {error}")
            if self.explicit_cancel_in_progress():
                raise failure
            self.finish(
                StreamEnd(
                    self.stream_id,
                    "error",
                    error=failure,
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
                if (
                    self.explicit_cancel_started
                    and not self.explicit_cancel_done.is_set()
                ):
                    raise ProtocolError("stream item arrived after stream end")
                return True
            if self.explicit_cancel_started:
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
        self.end_event.set()


class ProtocolConnection:
    """One multiplexed synchronous resource-protocol connection."""

    def __init__(self, socket_path: str, timeout: float, *, fallback_path: Optional[str] = None) -> None:
        self.socket_path = socket_path
        self.timeout = timeout
        self._wire = JsonLineConnection(
            socket_path,
            timeout,
            max_line_bytes=MAX_RESPONSE_BYTES + 1,
            fallback_path=fallback_path,
        )
        # Per-request deadlines are enforced by Pending events. The one shared
        # reader must remain idle indefinitely between requests and events.
        self._wire.set_timeout(None)
        self._lock = threading.Lock()
        self._request_cleanup_condition = threading.Condition(self._lock)
        self._pending: Dict[str, _Pending] = {}
        self._active_request_dispatches = 0
        self._active_request_cleanups: set[str] = set()
        self._streams: Dict[StreamId, _StreamState[Any]] = {}
        self._failed_open_cleanups: Dict[StreamId, _StreamState[Any]] = {}
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
        _on_dispatched: Optional[Callable[[], None]] = None,
        _on_send_error: Optional[Callable[[BaseException], None]] = None,
        _on_resource_error: Optional[Callable[[], None]] = None,
        _abandoned_result_decoder: Optional[Callable[[Any], Any]] = None,
        _bounded_dispatch: bool = False,
        _dispatch_guard: Optional[Callable[[], bool]] = None,
        _skip_request_cleanup_gate: bool = False,
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
        deadline = time.monotonic() + wait_for
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
        pending = _Pending(
            threading.Event(),
            on_resource_error=_on_resource_error,
            abandoned_result_decoder=_abandoned_result_decoder,
        )
        claimed_dispatch = False
        with self._request_cleanup_condition:
            if not _skip_request_cleanup_gate:
                while self._active_request_cleanups:
                    if self._closed:
                        raise self._closed_error()
                    if cancel_event is not None and cancel_event.is_set():
                        raise CancelledError(operation, dispatched=False)
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError(
                            f"{operation} did not dispatch before the deadline"
                        )
                    self._request_cleanup_condition.wait(
                        min(remaining, 0.01)
                    )
            if self._closed:
                raise self._closed_error()
            if cancel_event is not None and cancel_event.is_set():
                raise CancelledError(operation, dispatched=False)
            if deadline - time.monotonic() <= 0:
                raise TimeoutError(
                    f"{operation} did not dispatch before the deadline"
                )
            if not _skip_request_cleanup_gate:
                self._active_request_dispatches += 1
                claimed_dispatch = True
            self._pending[request_id] = pending
        try:
            try:
                if _bounded_dispatch:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError(
                            f"{operation} did not dispatch before the deadline"
                        )
                    if _dispatch_guard is None:
                        self._wire.send_bounded(envelope, remaining)
                    elif not self._wire.send_bounded_if(
                        envelope,
                        remaining,
                        _dispatch_guard,
                    ):
                        with self._lock:
                            self._pending.pop(request_id, None)
                        return _REQUEST_NOT_DISPATCHED
                else:
                    self._wire.send(envelope, on_sent=_on_dispatched)
            finally:
                if claimed_dispatch:
                    with self._request_cleanup_condition:
                        self._active_request_dispatches -= 1
                        self._request_cleanup_condition.notify_all()
        except BaseException as error:
            with self._lock:
                self._pending.pop(request_id, None)
            if _on_send_error is not None:
                _on_send_error(error)
            self._fail(error, attempt_cleanup=False)
            raise
        while not pending.event.is_set():
            if cancel_event is not None and cancel_event.is_set():
                cancellation = CancelledError(operation, dispatched=True)
                if (
                    _is_cancelable_terminal_wait(operation)
                    and self._begin_request_cleanup(
                        request_id,
                        pending,
                        cancellation,
                    )
                ):
                    self._cleanup_abandoned_request(
                        request_id,
                        pending,
                    )
                    raise cancellation
                with self._lock:
                    self._pending.pop(request_id, None)
                if pending.event.is_set():
                    break
                raise cancellation
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timeout_error = TimeoutError(
                    f"{operation} did not respond before the deadline"
                )
                if (
                    _is_cancelable_terminal_wait(operation)
                    and self._begin_request_cleanup(
                        request_id,
                        pending,
                        timeout_error,
                    )
                ):
                    self._cleanup_abandoned_request(
                        request_id,
                        pending,
                    )
                    raise timeout_error
                with self._lock:
                    self._pending.pop(request_id, None)
                if pending.event.is_set():
                    break
                raise timeout_error
            pending.event.wait(min(remaining, 0.01))
        if pending.error is not None:
            raise pending.error
        assert pending.value is not None
        return _decode_response(pending.value)

    def _begin_request_cleanup(
        self,
        request_id: str,
        pending: _Pending,
        original_error: BaseException,
    ) -> bool:
        with self._request_cleanup_condition:
            if (
                self._pending.get(request_id) is not pending
                or pending.event.is_set()
            ):
                return False
            if pending.cleanup_started:
                return True
            pending.cleanup_started = True
            pending.abandoned_error = original_error
            self._active_request_cleanups.add(request_id)
            self._request_cleanup_condition.notify_all()
            return True

    def _cleanup_abandoned_request(
        self,
        request_id: str,
        pending: _Pending,
    ) -> None:
        cleanup_timeout = min(
            max(self.timeout, 0.1),
            REQUEST_CLEANUP_TIMEOUT,
        )
        deadline = time.monotonic() + cleanup_timeout
        try:
            with self._request_cleanup_condition:
                while self._active_request_dispatches:
                    if self._closed:
                        raise self._closed_error()
                    self._request_cleanup_condition.wait(
                        self._remaining_request_cleanup_time(deadline)
                    )
            result = self.request(
                Operations.REQUEST_CANCEL.wire_name,
                {"request_id": request_id},
                timeout=self._remaining_request_cleanup_time(deadline),
                _bounded_dispatch=True,
                _skip_request_cleanup_gate=True,
            )
            canceled = _decode_request_cancel_result(result)
            if canceled:
                with self._lock:
                    if pending.response_received:
                        raise ProtocolError(
                            "request.cancel returned canceled true after "
                            "the target responded"
                        )
                    if self._pending.get(request_id) is pending:
                        self._pending.pop(request_id, None)
            else:
                if not pending.event.wait(
                    self._remaining_request_cleanup_time(deadline)
                ):
                    raise TimeoutError(
                        "request cancellation did not receive the completed "
                        "target response"
                    )
                with self._lock:
                    response_received = pending.response_received
                    response_error = pending.error
                    response_value = pending.value
                if not response_received:
                    if response_error is not None:
                        raise response_error
                    raise ProtocolError(
                        "request cancellation did not receive the completed "
                        "target response"
                    )
                if response_error is None:
                    if response_value is None:
                        raise ProtocolError(
                            "request cancellation received no completed "
                            "target response value"
                        )
                    result = _decode_response(response_value)
                    if pending.abandoned_result_decoder is not None:
                        pending.abandoned_result_decoder(result)
        except BaseException as error:
            if not self.closed:
                failure: BaseException
                if isinstance(error, ProtocolError):
                    failure = error
                else:
                    failure = CmuxConnectionError(
                        "request cancellation was not confirmed: "
                        f"{error}"
                    )
                self._fail(failure, attempt_cleanup=False)
        finally:
            with self._request_cleanup_condition:
                if self._pending.get(request_id) is pending:
                    self._pending.pop(request_id, None)
                self._active_request_cleanups.discard(request_id)
                self._request_cleanup_condition.notify_all()

    @staticmethod
    def _remaining_request_cleanup_time(deadline: float) -> float:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(
                "request cancellation did not finish before the deadline"
            )
        return remaining

    def open_stream(
        self,
        operation: str,
        params: Mapping[str, Any],
        decode_item: Callable[[Any], ItemT],
        *,
        timeout: Optional[float] = None,
        cancel_event: Optional[_CancellationSignal] = None,
        validate_item: Optional[
            Callable[[ItemT, Optional[Cursor]], None]
        ] = None,
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
            validate_item,
        )
        with self._lock:
            if self._closed:
                raise self._closed_error()
            self._streams[stream_id] = state
        stream_params = dict(params)
        stream_params["stream_id"] = str(stream_id)
        try:
            opened = self.request(
                operation,
                stream_params,
                timeout=timeout,
                cancel_event=cancel_event,
                _on_dispatched=state.mark_open_dispatched,
                _on_send_error=state.mark_open_send_failed,
                _on_resource_error=state.mark_open_rejected,
            )
            if state.open_send_failed:
                assert state.open_send_error is not None
                raise state.open_send_error
            state.attachment_lease = _validate_stream_open_result(
                operation,
                stream_id,
                opened,
            )
            with self._lock:
                if self._closed:
                    raise self._closed_error()
                state.mark_open_acknowledged()
        except BaseException as error:
            if state.open_send_failed:
                with self._lock:
                    self._streams.pop(stream_id, None)
            elif not state.open_rejected:
                self._cleanup_failed_stream_open(state, operation)
            else:
                with self._lock:
                    self._streams.pop(stream_id, None)
            raise
        return ResourceStream(self, state)

    def cancel_stream(self, state: _StreamState[Any]) -> None:
        cleanup_timeout = min(
            max(self.timeout, 0.1),
            STREAM_CLEANUP_TIMEOUT,
        )
        action, cached_error, deadline = state.begin_explicit_cancel(
            time.monotonic() + cleanup_timeout
        )
        if action == "failed":
            assert cached_error is not None
            raise cached_error
        if action == "completed":
            return
        if action == "waiting":
            try:
                remaining = self._remaining_cancel_time(deadline)
            except TimeoutError:
                remaining = 0
            if not state.explicit_cancel_done.wait(remaining):
                error = TimeoutError(
                    "stream cancellation did not finish before the deadline"
                )
                raise self._finalize_explicit_cancel_failure(
                    state,
                    error,
                    deadline,
                )
            cached_error = state.explicit_cancel_outcome()
            if cached_error is not None:
                raise cached_error
            return

        try:
            self._request_stream_cancel(
                state,
                failed_open=False,
                timeout=self._remaining_cancel_time(deadline),
            )
            remaining = self._remaining_cancel_time(deadline)
            if not state.end_event.wait(remaining):
                raise TimeoutError(
                    "stream cancellation did not finish before the deadline"
                )
            end = state.end
            if end is None:
                raise ProtocolError("stream cancellation omitted stream end")
            if end.reason != "canceled":
                raise ProtocolError(
                    "stream cancellation requires a canceled stream end"
                )
        except BaseException as error:
            raise self._finalize_explicit_cancel_failure(
                state,
                error,
                deadline,
            )
        self.forget_stream(state.stream_id)
        state.complete_explicit_cancel()

    def _finalize_explicit_cancel_failure(
        self,
        state: _StreamState[Any],
        error: BaseException,
        deadline: float,
    ) -> BaseException:
        failure, owns_finalization = state.claim_explicit_cancel_failure(error)
        if owns_finalization:
            try:
                self.forget_stream(state.stream_id)
                if not self.closed:
                    self._fail(
                        CmuxConnectionError(
                            "stream cancellation was not confirmed; connection "
                            f"closed to release remote stream state: {failure}"
                        )
                    )
                elif threading.current_thread() is not self._reader:
                    self._reader.join(
                        timeout=max(0.0, deadline - time.monotonic())
                    )
            finally:
                state.complete_explicit_cancel()
            return failure

        finalization_wait = max(0.0, deadline - time.monotonic()) + 0.1
        if not state.explicit_cancel_done.wait(finalization_wait):
            self.forget_stream(state.stream_id)
            if not self.closed:
                self._fail(
                    CmuxConnectionError(
                        "stream cancellation was not confirmed; connection "
                        f"closed to release remote stream state: {failure}"
                    )
                )
            state.complete_explicit_cancel()
        return failure

    @staticmethod
    def _remaining_cancel_time(deadline: float) -> float:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(
                "stream cancellation did not finish before the deadline"
            )
        return remaining

    def forget_stream(self, stream_id: StreamId) -> None:
        with self._lock:
            self._streams.pop(stream_id, None)

    def close(self) -> None:
        with self._request_cleanup_condition:
            if self._closed:
                return
            self._closed = True
            error = CmuxConnectionError("resource connection is closed")
            self._failure = error
            pending = tuple(self._pending.values())
            self._pending.clear()
            streams = tuple(self._streams.values()) + tuple(
                self._failed_open_cleanups.values()
            )
            self._streams.clear()
            self._failed_open_cleanups.clear()
            self._request_cleanup_condition.notify_all()
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
            response_error: Optional[ResourceError] = None
            try:
                _decode_response(envelope)
            except ResourceError as error:
                response_error = error
            request_id = envelope["id"]
            assert isinstance(request_id, str)
            # Response state, wakeup, and route removal are published under
            # one lock so a simultaneous local deadline cannot observe an
            # absent route before the typed response is available.
            with self._lock:
                pending = self._pending.get(request_id)
                if pending is not None:
                    pending.response_received = True
                    if response_error is not None:
                        if pending.on_resource_error is not None:
                            pending.on_resource_error()
                        pending.error = response_error
                    else:
                        pending.value = envelope
                    pending.event.set()
                    self._pending.pop(request_id, None)
            return
        if envelope_type in {"stream_item", "stream_end"}:
            raw_stream_id = envelope.get("stream_id")
            try:
                stream_id = StreamId(raw_stream_id)
            except (TypeError, ValueError) as error:
                raise ProtocolError(f"invalid stream_id: {error}") from error
            decoded_item: Optional[tuple[str, Optional[Cursor], Any]] = None
            decoded_end: Optional[StreamEnd] = None
            if envelope_type == "stream_item":
                decoded_item = _decode_stream_item_envelope(
                    stream_id,
                    envelope,
                )
            else:
                decoded_end = _decode_stream_end(stream_id, envelope)
            with self._lock:
                stream = self._streams.get(stream_id)
                canceling = tuple(
                    state
                    for state in self._streams.values()
                    if state.explicit_cancel_in_progress()
                )
            if stream is None:
                if envelope_type == "stream_end" and canceling:
                    raise ProtocolError(
                        "stream end ID does not match the canceling stream"
                    )
                return
            if envelope_type == "stream_item":
                assert decoded_item is not None
                if not stream.push(envelope, *decoded_item):
                    self.forget_stream(stream_id)
                    threading.Thread(
                        target=self._cancel_stream_confirmed,
                        args=(stream,),
                        name=f"cmux-stream-cancel-{secrets.token_hex(4)}",
                        daemon=True,
                    ).start()
                return
            assert decoded_end is not None
            keep_cancel_route = stream.explicit_cancel_in_progress()
            stream.finish(decoded_end)
            if not keep_cancel_route:
                self.forget_stream(stream_id)
            return
        raise ProtocolError(f"unknown resource envelope type {envelope_type!r}")

    def _fail(
        self,
        error: BaseException,
        *,
        attempt_cleanup: bool = True,
    ) -> None:
        if not isinstance(
            error,
            (CmuxConnectionError, ProtocolError, TimeoutError),
        ):
            error = CmuxConnectionError(str(error))
        with self._request_cleanup_condition:
            if self._closed:
                return
            self._closed = True
            self._failure = error
            pending = tuple(self._pending.values())
            self._pending.clear()
            streams = tuple(self._streams.values()) + tuple(
                self._failed_open_cleanups.values()
            )
            self._streams.clear()
            self._failed_open_cleanups.clear()
            self._request_cleanup_condition.notify_all()
        for item in pending:
            item.error = error
            item.event.set()
        if attempt_cleanup:
            cleanup_deadline = time.monotonic() + STREAM_CLEANUP_TIMEOUT
            for stream in streams:
                remaining = cleanup_deadline - time.monotonic()
                if remaining <= 0:
                    break
                self._cancel_stream_best_effort(
                    stream,
                    failed_open=True,
                    timeout=remaining,
                )
        for stream in streams:
            stream.finish(StreamEnd(stream.stream_id, "error", error=error))
        self._wire.close()
        if threading.current_thread() is not self._reader:
            self._reader.join(timeout=max(self.timeout, 0.1) + 0.5)

    def _closed_error(self) -> BaseException:
        return self._failure or CmuxConnectionError("resource connection is closed")

    def _cleanup_failed_stream_open(
        self,
        state: _StreamState[Any],
        operation: str,
    ) -> None:
        # Move the route and claim cleanup atomically with connection failure.
        # Late stream frames are ignored, while a concurrent _fail still sees
        # the cleanup route and races for the same one-shot wire dispatch.
        with self._lock:
            if self._closed:
                return
            self._streams.pop(state.stream_id, None)
            if not state.begin_failed_open_cleanup():
                return
            self._failed_open_cleanups[state.stream_id] = state
        try:
            self._request_stream_cancel(
                state,
                failed_open=True,
                operation=operation,
            )
        except BaseException as cleanup_error:
            if not self.closed:
                self._fail(
                    CmuxConnectionError(
                        f"{operation} failed-open cleanup was not confirmed: "
                        f"{cleanup_error}"
                    )
                )
        finally:
            with self._lock:
                self._failed_open_cleanups.pop(state.stream_id, None)

    def _cancel_stream_confirmed(
        self,
        state: _StreamState[Any],
        *,
        propagate: bool = False,
    ) -> None:
        if not state.begin_stream_cleanup():
            return
        try:
            self._request_stream_cancel(state, failed_open=False)
        except BaseException as cancel_error:
            if not self.closed:
                self._fail(
                    CmuxConnectionError(
                        "stream.cancel was not confirmed; connection closed "
                        f"to release remote stream state: {cancel_error}"
                    )
                )
            if propagate:
                raise

    def _request_stream_cancel(
        self,
        state: _StreamState[Any],
        *,
        failed_open: bool,
        operation: Optional[str] = None,
        timeout: Optional[float] = None,
    ) -> bool:
        def fail_cancel_send(error: BaseException) -> None:
            if failed_open and operation is not None:
                message = (
                    f"{operation} failed-open cleanup was not confirmed: "
                    f"{error}"
                )
            else:
                message = (
                    "stream.cancel was not confirmed; connection closed "
                    f"to release remote stream state: {error}"
                )
            self._fail(
                CmuxConnectionError(message),
                attempt_cleanup=False,
            )

        result = self.request(
            Operations.STREAM_CANCEL.wire_name,
            {
                **state.cancel_route,
                "stream": str(state.stream_id),
            },
            timeout=(
                min(max(self.timeout, 0.1), STREAM_CLEANUP_TIMEOUT)
                if timeout is None
                else timeout
            ),
            _on_send_error=fail_cancel_send,
            _bounded_dispatch=True,
            _dispatch_guard=lambda: state.begin_cancel_dispatch(
                failed_open=failed_open
            ),
        )
        if result is _REQUEST_NOT_DISPATCHED:
            return False
        if not isinstance(result, Mapping) or result:
            raise ProtocolError(
                "stream.cancel cleanup result must be an empty object"
            )
        return True

    def _cancel_stream_best_effort(
        self,
        state: _StreamState[Any],
        *,
        failed_open: bool = False,
        timeout: float = STREAM_CLEANUP_TIMEOUT,
    ) -> None:
        try:
            self._wire.send_bounded_if(
                {
                    "protocol": PROTOCOL,
                    "type": "request",
                    "id": f"request-{secrets.token_hex(16)}",
                    "operation": Operations.STREAM_CANCEL.wire_name,
                    "params": {
                        **state.cancel_route,
                        "stream": str(state.stream_id),
                    },
                },
                timeout,
                lambda: state.begin_cancel_dispatch(
                    failed_open=failed_open
                ),
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
    def attachment_lease(self) -> Optional[str]:
        """Lease required to size or release a terminal/browser attachment."""
        return self._state.attachment_lease

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
        self._connection.cancel_stream(self._state)

    def close(self) -> None:
        self.cancel()

    def __enter__(self) -> "ResourceStream[ItemT]":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.cancel()


def _is_cancelable_terminal_wait(operation: str) -> bool:
    return operation in {"terminal.wait", "terminal.wait_exit"}


def _decode_request_cancel_result(value: Any) -> bool:
    if (
        not isinstance(value, Mapping)
        or set(value) != {"canceled"}
        or not isinstance(value["canceled"], bool)
    ):
        raise ProtocolError(
            "request.cancel result must contain exactly boolean canceled"
        )
    return value["canceled"]


def _decode_response(envelope: Mapping[str, Any]) -> Any:
    allowed = {"protocol", "type", "id", "ok", "result", "error"}
    unknown = set(envelope) - allowed
    if unknown:
        field = min(unknown)
        raise ProtocolError(
            f"response contains unknown field {field!r}"
        )
    required = {"protocol", "type", "id", "ok"}
    missing = required - set(envelope)
    if missing:
        field = min(missing)
        raise ProtocolError(f"response omitted required field {field!r}")
    if envelope["protocol"] != PROTOCOL:
        raise ProtocolError("response has the wrong protocol")
    if envelope["type"] != "response":
        raise ProtocolError("response type must be 'response'")
    request_id = envelope["id"]
    if (
        not isinstance(request_id, str)
        or not 1 <= len(request_id) <= 128
    ):
        raise ProtocolError("response id must contain 1 to 128 characters")
    if not isinstance(envelope["ok"], bool):
        raise ProtocolError("response ok must be a boolean")
    if envelope["ok"] is True and "result" in envelope and "error" not in envelope:
        return envelope["result"]
    if envelope["ok"] is False and "error" in envelope and "result" not in envelope:
        error = envelope["error"]
        if not isinstance(error, Mapping):
            raise ProtocolError("error response must contain an error object")
        raise _decode_resource_error(error)
    raise ProtocolError("response must contain exactly one result or error")


def _validate_stream_open_result(
    operation: str,
    expected_stream_id: StreamId,
    value: Any,
) -> Optional[str]:
    if not isinstance(value, Mapping):
        raise ProtocolError(f"{operation} stream-open result must be an object")
    view_attachment = operation in {"terminal.attach", "browser.attach"}
    allowed = {"stream_id", "cursor"}
    if view_attachment:
        allowed.add("attachment_lease")
    unknown = set(value) - allowed
    if unknown:
        field = min(unknown)
        raise ProtocolError(
            f"{operation} stream-open result contains unknown field {field!r}"
        )
    if "stream_id" not in value:
        raise ProtocolError(f"{operation} stream-open result omitted stream_id")
    try:
        returned_stream_id = StreamId(value["stream_id"])
    except (TypeError, ValueError) as error:
        raise ProtocolError(
            f"{operation} stream-open result has invalid stream_id: {error}"
        ) from error
    if returned_stream_id != expected_stream_id:
        raise ProtocolError(f"{operation} returned a different stream_id")
    attachment_lease: Optional[str] = None
    if view_attachment:
        raw_lease = value.get("attachment_lease")
        if not isinstance(raw_lease, str):
            raise ProtocolError(
                f"{operation} stream-open result omitted attachment_lease"
            )
        try:
            lease_bytes = len(raw_lease.encode("utf-8"))
        except UnicodeEncodeError as error:
            raise ProtocolError(
                f"{operation} returned an invalid attachment_lease"
            ) from error
        if not 1 <= lease_bytes <= 128:
            raise ProtocolError(
                f"{operation} attachment_lease must contain 1 to 128 UTF-8 bytes"
            )
        attachment_lease = raw_lease
    if "cursor" in value:
        if value["cursor"] is None:
            raise ProtocolError(f"{operation} returned a null stream cursor")
        try:
            _decode_cursor(value["cursor"])
        except (TypeError, ValueError) as error:
            raise ProtocolError(
                f"{operation} returned an invalid stream cursor: {error}"
            ) from error
    return attachment_lease


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
    if set(error) != {"code", "message", "details", "retryable"}:
        raise ProtocolError(
            "error response must contain exactly code, message, details, "
            "and retryable"
        )
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
    allowed = {
        "protocol",
        "type",
        "stream_id",
        "reason",
        "cursor",
        "error",
        "recovery",
    }
    unknown = set(envelope) - allowed
    if unknown:
        field = min(unknown)
        raise ProtocolError(
            f"stream end contains unknown field {field!r}"
        )
    required = {"protocol", "type", "stream_id", "reason"}
    missing = required - set(envelope)
    if missing:
        field = min(missing)
        raise ProtocolError(
            f"stream end omitted required field {field!r}"
        )
    if envelope["protocol"] != PROTOCOL:
        raise ProtocolError("stream end has the wrong protocol")
    if envelope["type"] != "stream_end":
        raise ProtocolError("stream end type must be 'stream_end'")
    try:
        actual_stream_id = StreamId(envelope["stream_id"])
    except (TypeError, ValueError) as error:
        raise ProtocolError(f"stream end has invalid stream_id: {error}") from error
    if actual_stream_id != stream_id:
        raise ProtocolError("stream end ID does not match its route")
    reason = envelope["reason"]
    if reason not in {"completed", "canceled", "closed", "gap", "error"}:
        raise ProtocolError("stream end has invalid reason")
    cursor: Optional[Cursor] = None
    if "cursor" in envelope:
        if envelope["cursor"] is None:
            raise ProtocolError("stream end cursor must not be null")
        try:
            cursor = _decode_cursor(envelope["cursor"])
        except (TypeError, ValueError) as error:
            raise ProtocolError(f"stream end has invalid cursor: {error}") from error
    error_value = envelope.get("error")
    error: Optional[BaseException] = None
    if "error" in envelope:
        if not isinstance(error_value, Mapping):
            raise ProtocolError("stream error must be an object")
        error = _decode_resource_error(error_value)
    if (reason == "error") != ("error" in envelope):
        raise ProtocolError(
            "stream error is required exactly when reason is error"
        )
    recovery: Optional[str] = None
    if "recovery" in envelope:
        recovery_value = envelope["recovery"]
        if not isinstance(recovery_value, str):
            raise ProtocolError("stream recovery must be a string")
        recovery = recovery_value
    return StreamEnd(
        stream_id,
        reason,
        cursor,
        error,
        recovery,
    )


def _decode_stream_item_envelope(
    stream_id: StreamId,
    envelope: Mapping[str, Any],
) -> tuple[str, Optional[Cursor], Any]:
    allowed = {
        "protocol",
        "type",
        "stream_id",
        "sequence",
        "cursor",
        "item",
    }
    unknown = set(envelope) - allowed
    if unknown:
        field = min(unknown)
        raise ProtocolError(
            f"stream item contains unknown field {field!r}"
        )
    required = {"protocol", "type", "stream_id", "sequence", "item"}
    missing = required - set(envelope)
    if missing:
        field = min(missing)
        raise ProtocolError(
            f"stream item omitted required field {field!r}"
        )
    if envelope["protocol"] != PROTOCOL:
        raise ProtocolError("stream item has the wrong protocol")
    if envelope["type"] != "stream_item":
        raise ProtocolError("stream item type must be 'stream_item'")
    try:
        actual_stream_id = StreamId(envelope["stream_id"])
    except (TypeError, ValueError) as error:
        raise ProtocolError(f"stream item has invalid stream_id: {error}") from error
    if actual_stream_id != stream_id:
        raise ProtocolError("stream item ID does not match its route")
    try:
        sequence = _decimal(envelope["sequence"], "stream sequence")
    except (TypeError, ValueError) as error:
        raise ProtocolError(f"stream item has invalid sequence: {error}") from error
    cursor: Optional[Cursor] = None
    if "cursor" in envelope:
        if envelope["cursor"] is None:
            raise ProtocolError("stream item cursor must not be null")
        try:
            cursor = _decode_cursor(envelope["cursor"])
        except (TypeError, ValueError) as error:
            raise ProtocolError(f"stream item has invalid cursor: {error}") from error
    return sequence, cursor, envelope["item"]


__all__ = [
    "MAX_REQUEST_BYTES",
    "MAX_RESPONSE_BYTES",
    "MAX_STREAM_BYTES",
    "MAX_STREAM_MESSAGES",
    "PROTOCOL",
    "ProtocolConnection",
    "ResourceStream",
]
