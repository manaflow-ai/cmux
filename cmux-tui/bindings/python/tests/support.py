from __future__ import annotations

import json
import os
import shutil
import socket
import tempfile
import threading
from typing import Callable


ConnectionHandler = Callable[[socket.socket, int], None]


def receive_frame(connection: socket.socket) -> dict:
    buffer = bytearray()
    while True:
        chunk = connection.recv(4096)
        if not chunk:
            raise EOFError
        buffer.extend(chunk)
        newline = buffer.find(b"\n")
        if newline >= 0:
            return json.loads(bytes(buffer[:newline]))


def send_frame(connection: socket.socket, value: dict) -> None:
    connection.sendall(
        json.dumps(value, separators=(",", ":")).encode("utf-8") + b"\n"
    )


class UnixJsonServer:
    def __init__(self, handler: ConnectionHandler) -> None:
        self._handler = handler
        self._root = tempfile.mkdtemp(prefix="cmuxpy-", dir="/tmp")
        self.path = os.path.join(self._root, "mux.sock")
        self._listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._listener.bind(self.path)
        self._listener.listen()
        self._listener.settimeout(0.1)
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self._accept = threading.Thread(target=self._accept_loop, daemon=True)
        self._accept.start()

    def _accept_loop(self) -> None:
        index = 0
        while not self._stop.is_set():
            try:
                connection, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            thread = threading.Thread(
                target=self._run_handler,
                args=(connection, index),
                daemon=True,
            )
            index += 1
            self._threads.append(thread)
            thread.start()

    def _run_handler(self, connection: socket.socket, index: int) -> None:
        with connection:
            try:
                self._handler(connection, index)
            except (BrokenPipeError, ConnectionError, EOFError, OSError):
                pass

    def close(self) -> None:
        self._stop.set()
        self._listener.close()
        self._accept.join(timeout=1)
        for thread in self._threads:
            thread.join(timeout=1)
        shutil.rmtree(self._root, ignore_errors=True)

    def __enter__(self) -> "UnixJsonServer":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()
