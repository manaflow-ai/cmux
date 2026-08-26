from __future__ import annotations

import threading
import weakref
import os
from collections import deque
from dataclasses import fields, is_dataclass
from enum import Enum
from typing import Any, Callable, Deque, Dict, Iterator, Mapping, Optional

from ._generated.client import GeneratedClientMixin
from ._generated.codec import (
    ProtocolDecodeError,
    decode_command_result,
    decode_event,
    encode_request,
)
from ._generated.metadata import COMMANDS, CommandMetadata
from ._generated.models import AnyEvent, MISSING, MissingType, ReadScrollbackResult
from ..errors import (
    AuthorityError,
    CmuxConnectionError,
    CmuxError,
    CommandError,
    ProtocolError,
    TimeoutError,
)
from ..client_defaults import (
    _legacy_raw_socket_fallback_path,
    default_socket_path,
    env_socket_path,
)
from ..transport import DEFAULT_MAX_LINE_BYTES, JsonLineConnection


DEFAULT_MAX_PRE_ACK_EVENTS = 256
DEFAULT_MAX_IGNORED_FRAMES = 256

def _json_value(value: Any) -> Any:
    if value is MISSING:
        return MISSING
    if isinstance(value, Enum):
        return value.value
    if is_dataclass(value):
        return {
            item.metadata.get("wire_name", item.name): encoded
            for item in fields(value)
            if not item.metadata.get("cmux_skip")
            and (encoded := _json_value(getattr(value, item.name))) is not MISSING
        }
    if isinstance(value, Mapping):
        return {
            str(key): encoded
            for key, item in value.items()
            if (encoded := _json_value(item)) is not MISSING
        }
    if isinstance(value, (tuple, list)):
        return [_json_value(item) for item in value]
    return value


class _Stream(Iterator[AnyEvent]):
    def __init__(
        self,
        client: "CmuxClient",
        command: str,
        payload: Mapping[str, Any],
    ) -> None:
        self._client_ref = weakref.ref(client)
        self._conn = JsonLineConnection(
            client.socket_path,
            client.timeout,
            max_line_bytes=client.max_line_bytes,
            fallback_path=client._fallback_socket_path,
        )
        self._queue: Deque[AnyEvent] = deque()
        self._closed = False
        self.response: Optional[Mapping[str, Any]] = None
        client._register_stream(self)
        request = {"id": client._next_id(), "cmd": command, **payload}
        request_id = request["id"]
        ignored = 0
        try:
            self._conn.send(request)
            while True:
                value = self._conn.recv()
                if "event" in value:
                    if len(self._queue) >= client.max_pre_ack_events:
                        raise ProtocolError(
                            "stream produced too many events before its acknowledgement"
                        )
                    try:
                        self._queue.append(decode_event(value))
                    except (ProtocolDecodeError, TypeError, ValueError) as error:
                        raise ProtocolError(f"invalid event frame: {error}") from error
                    continue
                if value.get("id") != request_id:
                    ignored += 1
                    if ignored > client.max_ignored_frames:
                        raise ProtocolError(
                            "stream received too many unrelated response frames"
                        )
                    continue
                if value.get("ok") is True:
                    self.response = value
                    break
                raise CommandError(str(value.get("error", "unknown error")), value)
        except BaseException:
            self.close()
            raise

    @property
    def timeout(self) -> float:
        return self._conn.timeout

    @timeout.setter
    def timeout(self, value: float) -> None:
        self._conn.set_timeout(value)

    def __iter__(self) -> "_Stream":
        return self

    def __next__(self) -> AnyEvent:
        return self._next()

    def _next(
        self,
        before_wait: Optional[Callable[[], None]] = None,
    ) -> AnyEvent:
        if self._closed:
            raise StopIteration
        if self._queue:
            event = self._queue.popleft()
            if getattr(event, "event", None) in {"detached", "overflow"}:
                self.close()
            return event
        ignored = 0
        while not self._closed:
            try:
                value = (
                    self._conn.recv()
                    if before_wait is None
                    else self._conn._recv(before_wait=before_wait)
                )
            except CmuxConnectionError:
                if self._closed:
                    raise StopIteration
                raise
            if "event" not in value:
                ignored += 1
                client = self._client_ref()
                limit = (
                    client.max_ignored_frames
                    if client is not None
                    else DEFAULT_MAX_IGNORED_FRAMES
                )
                if ignored > limit:
                    self.close()
                    raise ProtocolError(
                        "stream received too many non-event response frames"
                    )
                continue
            try:
                event = decode_event(value)
            except (ProtocolDecodeError, TypeError, ValueError) as error:
                self.close()
                raise ProtocolError(f"invalid event frame: {error}") from error
            if getattr(event, "event", None) in {"detached", "overflow"}:
                self.close()
            return event
        raise StopIteration

    def iter_bytes(self) -> Iterator[bytes]:
        for event in self:
            value = event.bytes_data
            if value is not None:
                yield value

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._conn.close()
        client = self._client_ref()
        if client is not None:
            client._unregister_stream(self)

    def __enter__(self) -> "_Stream":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()


class EventStream(_Stream):
    """A subscription stream with typed protocol events."""


class AttachStream(_Stream):
    """A byte, render, or browser attachment stream."""


class CmuxClient(GeneratedClientMixin):
    """Synchronous, standard-library-only cmux protocol client."""

    def __init__(
        self,
        socket_path: Optional[str] = None,
        session: str = "main",
        timeout: float = 10.0,
        *,
        max_line_bytes: int = DEFAULT_MAX_LINE_BYTES,
        max_pre_ack_events: int = DEFAULT_MAX_PRE_ACK_EVENTS,
        max_ignored_frames: int = DEFAULT_MAX_IGNORED_FRAMES,
        allow_protocol_v6_attach: bool = True,
        allow_provider_authority: bool = False,
    ) -> None:
        if max_pre_ack_events < 1 or max_ignored_frames < 1:
            raise ValueError("stream buffer limits must be positive")
        explicit = socket_path or env_socket_path()
        self.socket_path = explicit or default_socket_path(session)
        self._fallback_socket_path = (
            _legacy_raw_socket_fallback_path(session)
            if not explicit
            and os.path.basename(os.path.dirname(self.socket_path)).startswith(
                "cmux-tui-hashed-"
            )
            else None
        )
        self.timeout = timeout
        self.max_line_bytes = max_line_bytes
        self.max_pre_ack_events = max_pre_ack_events
        self.max_ignored_frames = max_ignored_frames
        # Retained as a source-compatible constructor parameter. Protocol 10
        # attachments are always decoded safely.
        self.allow_protocol_v6_attach = allow_protocol_v6_attach
        self.allow_provider_authority = allow_provider_authority
        self._conn = JsonLineConnection(
            self.socket_path,
            timeout,
            max_line_bytes=max_line_bytes,
            fallback_path=self._fallback_socket_path,
        )
        self._next_request_id = 1
        self._id_lock = threading.Lock()
        self._request_lock = threading.Lock()
        self._close_lock = threading.Lock()
        self._stream_lock = threading.Lock()
        self._streams: weakref.WeakSet[_Stream] = weakref.WeakSet()
        self._closed = False
        self._protocol: Optional[int] = None
        self._capabilities: set[str] = set()

    @property
    def protocol(self) -> Optional[int]:
        return self._protocol

    @property
    def capabilities(self) -> frozenset[str]:
        return frozenset(self._capabilities)

    @property
    def closed(self) -> bool:
        return self._closed

    def __enter__(self) -> "CmuxClient":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()

    def close(self) -> None:
        with self._close_lock:
            if self._closed:
                return
            self._closed = True
            with self._stream_lock:
                streams = tuple(self._streams)
            for stream in streams:
                stream.close()
            self._conn.close()

    def _register_stream(self, stream: _Stream) -> None:
        with self._stream_lock:
            closed = self._closed
            if not closed:
                self._streams.add(stream)
        if closed:
            stream.close()
            raise CmuxConnectionError("client is closed")

    def _unregister_stream(self, stream: _Stream) -> None:
        with self._stream_lock:
            self._streams.discard(stream)

    def _next_id(self) -> int:
        with self._id_lock:
            value = self._next_request_id
            self._next_request_id += 1
            return value

    def request(self, cmd: str, **params: Any) -> Dict[str, Any]:
        """Send a raw command, preserving explicit JSON null values."""

        if self._closed:
            raise CmuxConnectionError("client is closed")
        metadata = COMMANDS.get(cmd)
        if metadata is not None:
            self._ensure_authority(cmd, metadata)
        converted = _json_value(params)
        payload = {"id": self._next_id(), "cmd": cmd}
        payload.update(converted)
        request_id = payload["id"]
        ignored = 0
        with self._request_lock:
            self._conn.send(payload)
            while True:
                response = self._conn.recv()
                if "event" in response:
                    ignored += 1
                elif response.get("id") in (request_id, None):
                    return response
                else:
                    ignored += 1
                if ignored > self.max_ignored_frames:
                    raise ProtocolError(
                        "command connection received too many unrelated frames"
                    )

    def _request_data(self, command: str, params: Mapping[str, Any]) -> Any:
        response = self.request(command, **params)
        if response.get("ok") is not True:
            raise CommandError(str(response.get("error", "unknown error")), response)
        return response.get("data", {})

    def _ensure_command_supported(
        self, command: str, metadata: CommandMetadata
    ) -> None:
        self._ensure_authority(command, metadata)
        if command == "identify":
            return
        if self._protocol is None:
            GeneratedClientMixin.identify(self)
        assert self._protocol is not None
        if self._protocol < metadata.since:
            raise ProtocolError(
                f"{command} requires protocol {metadata.since}; "
                f"server uses protocol {self._protocol}"
            )
        if metadata.capability and metadata.capability not in self._capabilities:
            raise ProtocolError(
                f"{command} requires server capability {metadata.capability!r}"
            )

    def _ensure_authority(
        self, command: str, metadata: CommandMetadata
    ) -> None:
        if (
            metadata.authority == "provider-authority"
            and not self.allow_provider_authority
        ):
            raise AuthorityError(command, metadata.authority)

    def _ensure_request_fields_supported(
        self,
        command: str,
        metadata: CommandMetadata,
        payload: Mapping[str, Any],
    ) -> None:
        if self._protocol is None:
            return
        for field_name, field_metadata in metadata.fields.items():
            if field_name not in payload:
                continue
            if (
                field_metadata.since is not None
                and self._protocol < field_metadata.since
            ):
                raise ProtocolError(
                    f"{command}.{field_name} requires protocol "
                    f"{field_metadata.since}; server uses protocol {self._protocol}"
                )
            if (
                field_metadata.capability is not None
                and field_metadata.capability not in self._capabilities
            ):
                raise ProtocolError(
                    f"{command}.{field_name} requires server capability "
                    f"{field_metadata.capability!r}"
                )

    def _invoke_command(self, command: str, request: Any) -> Any:
        metadata = COMMANDS[command]
        self._ensure_command_supported(command, metadata)
        try:
            payload = encode_request(command, request)
        except (ProtocolDecodeError, TypeError, ValueError) as error:
            raise ProtocolError(f"invalid {command} request: {error}") from error
        self._ensure_request_fields_supported(command, metadata, payload)
        data = self._request_data(command, payload)
        try:
            result = decode_command_result(command, data)
        except (ProtocolDecodeError, TypeError, ValueError) as error:
            raise ProtocolError(f"invalid {command} result: {error}") from error
        if command == "identify":
            self._protocol = int(result.protocol)
            capabilities = getattr(result, "capabilities", MISSING)
            self._capabilities = (
                {str(value) for value in capabilities}
                if capabilities is not MISSING and capabilities is not None
                else set()
            )
        return result

    def _open_command_stream(self, command: str, request: Any) -> _Stream:
        metadata = COMMANDS[command]
        self._ensure_command_supported(command, metadata)
        try:
            payload = encode_request(command, request)
        except (ProtocolDecodeError, TypeError, ValueError) as error:
            raise ProtocolError(f"invalid {command} request: {error}") from error
        self._ensure_request_fields_supported(command, metadata, payload)
        if command == "attach-surface":
            cols = payload.get("cols", MISSING)
            rows = payload.get("rows", MISSING)
            if (cols is MISSING) != (rows is MISSING):
                raise ValueError(
                    "attach-surface cols and rows must be supplied together"
                )
        stream_type = AttachStream if metadata.stream_kind == "attach" else EventStream
        return stream_type(self, command, payload)

    def subscribe_deltas(
        self, *, surface: Any = MISSING
    ) -> EventStream:
        """Subscribe to stable tree delta events instead of invalidations."""

        return self.subscribe(tree_events="deltas", surface=surface)

    def attach_bytes(
        self,
        surface: int,
        *,
        cols: Any = MISSING,
        rows: Any = MISSING,
    ) -> AttachStream:
        """Attach to PTY bytes, or browser frames when the surface is a browser."""

        return self.attach_surface(
            surface, mode="bytes", cols=cols, rows=rows
        )

    def attach_render(
        self,
        surface: int,
        *,
        cols: Any = MISSING,
        rows: Any = MISSING,
    ) -> AttachStream:
        """Attach to typed render state and render delta events."""

        return self.attach_surface(
            surface, mode="render", cols=cols, rows=rows
        )

    def attach_browser(
        self,
        surface: int,
        *,
        cols: Any = MISSING,
        rows: Any = MISSING,
    ) -> AttachStream:
        """Attach to browser state and frame events."""

        return self.attach_surface(
            surface, mode="bytes", cols=cols, rows=rows
        )

    def use_only_client_size(self, surface: int, client: int) -> Any:
        return self.set_client_sizing(
            surface, enabled=True, client=client, exclusive=True
        )

    def use_all_client_sizes(self, surface: int) -> Any:
        return self.set_client_sizing(surface, enabled=True)

    def read_scrollback_tail(self, surface: int, count: int) -> ReadScrollbackResult:
        """Read up to ``count`` of the newest scrollback rows.

        This best-effort helper first reads a snapshot from row zero to learn
        the total, then reads the calculated tail when needed. Scrollback may
        change between those two snapshot-relative calls, so the result may
        skip or repeat rows during concurrent terminal output.
        """

        if isinstance(count, bool) or not isinstance(count, int):
            raise TypeError("scrollback row count must be an integer")
        if not 0 <= count <= 65_535:
            raise ValueError("scrollback row count must be between 0 and 65535")

        probe = self.read_scrollback(surface, start=0, count=count)
        start = max(0, probe.total - count)
        if start == 0:
            return probe
        return self.read_scrollback(surface, start=start, count=count)


__all__ = [
    "AttachStream",
    "CmuxClient",
    "EventStream",
    "default_socket_path",
    "env_socket_path",
    "AuthorityError",
    "CmuxError",
    "CommandError",
    "CmuxConnectionError",
    "ProtocolError",
    "TimeoutError",
    "MISSING",
    "MissingType",
]
