from __future__ import annotations

import json
import math
import select
import socket
import threading
import time
from typing import Any, Callable, Mapping, Optional

from .errors import CmuxConnectionError, ProtocolError, TimeoutError


DEFAULT_MAX_LINE_BYTES = 16 * 1024 * 1024


class JsonLineConnection:
    """One bounded JSON-lines connection to a cmux Unix socket."""

    def __init__(
        self,
        path: str,
        timeout: float,
        *,
        max_line_bytes: int = DEFAULT_MAX_LINE_BYTES,
    ) -> None:
        if max_line_bytes < 1:
            raise ValueError("max_line_bytes must be positive")
        self.path = path
        self.timeout = timeout
        self.max_line_bytes = max_line_bytes
        self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._socket.settimeout(timeout)
        self._wake_read, self._wake_write = socket.socketpair()
        self._wake_read_closed = False
        self._send_lock = threading.Lock()
        self._recv_lock = threading.Lock()
        self._close_lock = threading.Lock()
        self._buffer = bytearray()
        self._closed = False
        self._write_poisoned = False
        try:
            self._socket.connect(path)
        except OSError as error:
            self._socket.close()
            self._wake_read.close()
            self._wake_write.close()
            self._wake_read_closed = True
            self._closed = True
            raise CmuxConnectionError(
                f"cannot connect to session socket {path}: {error}"
            ) from error

    @property
    def closed(self) -> bool:
        return self._closed

    def set_timeout(self, timeout: Optional[float]) -> None:
        self.timeout = timeout
        self._socket.settimeout(timeout)

    def send(
        self,
        value: Mapping[str, Any],
        *,
        on_sent: Optional[Callable[[], None]] = None,
    ) -> None:
        encoded = self._encode(value)
        with self._send_lock:
            if self._write_poisoned:
                raise CmuxConnectionError(
                    "session socket write state is indeterminate"
                )
            try:
                self._send_encoded(encoded)
            except BaseException:
                # A socket error may follow a partial write. Poison the writer
                # before releasing the lock so no frame can be appended.
                self._write_poisoned = True
                raise
            if on_sent is not None:
                on_sent()

    def send_bounded_if(
        self,
        value: Mapping[str, Any],
        timeout: float,
        should_send: Callable[[], bool],
    ) -> bool:
        """Attempts one final bounded write when its synchronized guard wins."""
        if (
            isinstance(timeout, bool)
            or not isinstance(timeout, (int, float))
            or not math.isfinite(timeout)
            or timeout <= 0
        ):
            raise ValueError("send timeout must be finite and greater than zero")
        encoded = self._encode(value)
        deadline = time.monotonic() + timeout
        if not self._send_lock.acquire(timeout=timeout):
            raise TimeoutError("session socket write lock timed out")
        try:
            if self._write_poisoned:
                raise CmuxConnectionError(
                    "session socket write state is indeterminate"
                )
            if not should_send():
                return False
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("session socket write timed out")
            try:
                self._send_encoded_bounded(encoded, deadline)
            except BaseException:
                # Once dispatch reaches the socket, every exception may have
                # followed a partial frame and therefore poisons JSON framing.
                self._write_poisoned = True
                raise
            return True
        finally:
            self._send_lock.release()

    def send_bounded(
        self,
        value: Mapping[str, Any],
        timeout: float,
    ) -> None:
        """Writes one frame within the supplied total dispatch timeout."""
        self.send_bounded_if(value, timeout, lambda: True)

    def _encode(self, value: Mapping[str, Any]) -> bytes:
        try:
            encoded = json.dumps(
                value,
                ensure_ascii=False,
                separators=(",", ":"),
                allow_nan=False,
            ).encode("utf-8")
        except (TypeError, ValueError) as error:
            raise ProtocolError(f"request is not valid JSON: {error}") from error
        if len(encoded) + 1 > self.max_line_bytes:
            raise ProtocolError(
                f"request exceeds {self.max_line_bytes}-byte JSON-line limit"
            )
        return encoded

    def _send_encoded(self, encoded: bytes) -> None:
        if self._closed:
            raise CmuxConnectionError("session socket is closed")
        try:
            self._socket.sendall(encoded + b"\n")
        except socket.timeout as error:
            raise TimeoutError("session socket write timed out") from error
        except OSError as error:
            raise CmuxConnectionError(f"socket write failed: {error}") from error

    def _send_encoded_bounded(self, encoded: bytes, deadline: float) -> None:
        if self._closed:
            raise CmuxConnectionError("session socket is closed")
        remaining_bytes = memoryview(encoded + b"\n")
        while remaining_bytes:
            remaining_time = deadline - time.monotonic()
            if remaining_time <= 0:
                raise TimeoutError("session socket write timed out")
            try:
                _, writable, _ = select.select(
                    [],
                    [self._socket],
                    [],
                    remaining_time,
                )
            except (OSError, ValueError) as error:
                raise CmuxConnectionError(
                    f"socket write readiness check failed: {error}"
                ) from error
            if not writable:
                raise TimeoutError("session socket write timed out")
            try:
                sent = self._socket.send(
                    remaining_bytes,
                    socket.MSG_DONTWAIT,
                )
            except BlockingIOError:
                continue
            except socket.timeout as error:
                raise TimeoutError("session socket write timed out") from error
            except OSError as error:
                raise CmuxConnectionError(
                    f"socket write failed: {error}"
                ) from error
            if sent <= 0:
                raise CmuxConnectionError("socket write made no progress")
            remaining_bytes = remaining_bytes[sent:]

    def recv(self) -> dict[str, Any]:
        return self._recv()

    def _recv(
        self,
        *,
        before_wait: Optional[Callable[[], None]] = None,
    ) -> dict[str, Any]:
        with self._recv_lock:
            try:
                while True:
                    newline = self._buffer.find(b"\n")
                    if newline >= 0:
                        if newline + 1 > self.max_line_bytes:
                            self.close()
                            raise ProtocolError(
                                f"server frame exceeds {self.max_line_bytes}-byte JSON-line limit"
                            )
                        raw = bytes(self._buffer[:newline])
                        del self._buffer[: newline + 1]
                        break
                    if len(self._buffer) >= self.max_line_bytes:
                        self.close()
                        raise ProtocolError(
                            f"server frame exceeds {self.max_line_bytes}-byte JSON-line limit"
                        )
                    if self._closed:
                        raise CmuxConnectionError("session socket is closed")
                    if before_wait is not None:
                        before_wait()
                    try:
                        readable, _, _ = select.select(
                            [self._socket, self._wake_read],
                            [],
                            [],
                            self.timeout,
                        )
                    except (OSError, ValueError) as error:
                        if self._closed:
                            raise CmuxConnectionError(
                                "session socket is closed"
                            ) from error
                        raise CmuxConnectionError(
                            f"socket readiness check failed: {error}"
                        ) from error
                    if not readable:
                        raise TimeoutError("session did not respond")
                    if self._wake_read in readable:
                        try:
                            self._wake_read.recv(1)
                        except OSError:
                            pass
                        raise CmuxConnectionError("session socket is closed")
                    try:
                        chunk = self._socket.recv(
                            min(64 * 1024, self.max_line_bytes - len(self._buffer))
                        )
                    except socket.timeout as error:
                        raise TimeoutError("session did not respond") from error
                    except OSError as error:
                        if self._closed:
                            raise CmuxConnectionError(
                                "session socket is closed"
                            ) from error
                        raise CmuxConnectionError(
                            f"socket read failed: {error}"
                        ) from error
                    if not chunk:
                        raise CmuxConnectionError("session socket closed")
                    self._buffer.extend(chunk)
            finally:
                if self._closed:
                    self._close_wake_reader()
        try:
            value = json.loads(raw.decode("utf-8"))
        except UnicodeDecodeError as error:
            raise ProtocolError(f"server frame is not UTF-8: {error}") from error
        except json.JSONDecodeError as error:
            raise ProtocolError(f"bad JSON from server: {error}") from error
        if not isinstance(value, dict):
            raise ProtocolError("server JSON frame must be an object")
        return value

    def close(self) -> None:
        with self._close_lock:
            if self._closed:
                return
            self._closed = True
            try:
                self._wake_write.send(b"\0")
            except OSError:
                pass
            try:
                self._socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self._socket.close()
            self._wake_write.close()
            if self._recv_lock.acquire(blocking=False):
                try:
                    self._close_wake_reader_locked()
                finally:
                    self._recv_lock.release()

    def _close_wake_reader(self) -> None:
        with self._close_lock:
            self._close_wake_reader_locked()

    def _close_wake_reader_locked(self) -> None:
        if not self._wake_read_closed:
            self._wake_read_closed = True
            self._wake_read.close()

    def __enter__(self) -> "JsonLineConnection":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()


__all__ = ["DEFAULT_MAX_LINE_BYTES", "JsonLineConnection"]
