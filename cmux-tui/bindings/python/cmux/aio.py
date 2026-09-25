from __future__ import annotations

import asyncio
import functools
import math
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any, AsyncIterator, Callable, Generic, List, Optional, Set, TypeVar

from ._protocol import ResourceStream as SyncResourceStream
from .errors import TimeoutError
from .ids import (
    BrowserId,
    ConnectedClientId,
    MachineId,
    PairingRequestId,
    PaneId,
    ScreenId,
    SelectorInput,
    SessionId,
    SidebarViewId,
    TabId,
    TerminalId,
    WorkspaceId,
)
from .models import CreationResolution, MutationResult, StreamItem
from .options import RequestOptions
from .resources import (
    Agent as SyncAgent,
    Browser as SyncBrowser,
    Client as SyncClient,
    ConnectedClient as SyncConnectedClient,
    CreatedPath as SyncCreatedPath,
    FrontendProjection as SyncFrontendProjection,
    Machine as SyncMachine,
    Notification as SyncNotification,
    PairingRequest as SyncPairingRequest,
    Pane as SyncPane,
    Screen as SyncScreen,
    Session as SyncSession,
    SessionCreation as SyncSessionCreation,
    SidebarView as SyncSidebarView,
    Tab as SyncTab,
    Terminal as SyncTerminal,
    Workspace as SyncWorkspace,
)


ValueT = TypeVar("ValueT")
_ITERATION_END = object()


async def _await_cleanup(awaitable: Any) -> Any:
    """Finish cleanup after caller cancellation, then re-raise it.

    ``shield`` keeps the cleanup task alive, while the loop drains it even if
    cancellation is delivered again during shutdown.
    """
    task = asyncio.ensure_future(awaitable)
    cancelled = False
    while True:
        try:
            result = await asyncio.shield(task)
            break
        except asyncio.CancelledError:
            # A cancellation from the wrapped task itself must be propagated.
            # Retrying a completed cancelled task would otherwise spin.
            if task.done():
                result = task.result()
                cancelled = True
                break
            cancelled = True
            continue
    if cancelled:
        raise asyncio.CancelledError
    return result


def _next_or_end(
    stream: SyncResourceStream[ValueT],
    timeout: Optional[float],
) -> Any:
    try:
        return stream.next(timeout)
    except StopIteration:
        return _ITERATION_END


class ResourceStream(Generic[ValueT], AsyncIterator[StreamItem[ValueT]]):
    """Async adapter for a typed stream."""

    def __init__(
        self,
        owner: "Client",
        stream: SyncResourceStream[ValueT],
    ) -> None:
        self._owner = owner
        self._stream = stream
        self._executor = ThreadPoolExecutor(
            max_workers=1,
            thread_name_prefix=f"cmux-aio-stream-{stream.id}",
        )
        self._closed = False
        self._next_lock = asyncio.Lock()
        owner._register_stream(self)

    @property
    def id(self):
        return self._stream.id

    @property
    def end(self):
        return self._stream.end

    def __aiter__(self) -> "ResourceStream[ValueT]":
        return self

    async def __anext__(self) -> StreamItem[ValueT]:
        return await self.next()

    async def next(
        self,
        timeout: Optional[float] = None,
    ) -> StreamItem[ValueT]:
        if self._closed:
            raise StopAsyncIteration
        if timeout is not None and (
            isinstance(timeout, bool) or not isinstance(timeout, (int, float))
        ):
            raise TypeError("stream timeout must be a number")
        if timeout is not None and (
            not math.isfinite(timeout) or timeout <= 0
        ):
            raise ValueError("stream timeout must be finite and greater than zero")
        async with self._next_lock:
            loop = asyncio.get_running_loop()
            future = loop.run_in_executor(
                self._executor,
                _next_or_end,
                self._stream,
                timeout,
            )
            try:
                # Shield the executor future so cancellation reaches the stream
                # protocol below, rather than cancelling the asyncio wrapper.
                await asyncio.shield(future)
                value = future.result()
            except asyncio.CancelledError:
                await self.cancel()
                raise
            except TimeoutError:
                raise
            except BaseException:
                await self._retire()
                raise
        if value is _ITERATION_END:
            await self._retire()
            raise StopAsyncIteration
        return value

    async def cancel(self) -> None:
        if self._closed:
            return
        try:
            await self._owner._run_internal(self._stream.cancel)
        finally:
            await self._retire()

    async def aclose(self) -> None:
        await self.cancel()

    async def __aenter__(self) -> "ResourceStream[ValueT]":
        return self

    async def __aexit__(
        self,
        _type: object,
        _value: object,
        _traceback: object,
    ) -> None:
        await self.cancel()

    async def _retire(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._owner._unregister_stream(self)
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(
            None,
            functools.partial(self._executor.shutdown, wait=True),
        )


@dataclass(frozen=True)
class CreatedPath:
    kind: str
    workspace: "Workspace"
    screen: Optional["Screen"] = None
    pane: Optional["Pane"] = None
    tab: Optional["Tab"] = None
    terminal: Optional["Terminal"] = None
    browser: Optional["Browser"] = None

    @property
    def content(self):
        return self.terminal or self.browser


class Client:
    """Standard-library asyncio adapter.

    Requests share a multiplexed connection. Stream reads use dedicated
    workers, so waiting for one stream cannot occupy a request worker.
    """

    def __init__(
        self,
        socket_path: Optional[str] = None,
        session: str = "main",
        timeout: float = 10.0,
        **options: Any,
    ) -> None:
        self._sync = SyncClient(socket_path, session, timeout, **options)
        self._executor = ThreadPoolExecutor(
            max_workers=4,
            thread_name_prefix="cmux-aio-request",
        )
        self._closed = False
        self._closing = False
        self._close_task: Optional[asyncio.Task[None]] = None
        self._streams: Set[ResourceStream[Any]] = set()

    @property
    def socket_path(self) -> str:
        return self._sync.socket_path

    @property
    def closed(self) -> bool:
        return self._closed

    def machine(self, selector: SelectorInput[MachineId]) -> "Machine":
        return Machine(self, self._sync.machine(selector))

    def session(
        self,
        selector: SelectorInput[SessionId],
        *,
        machine: Optional[SelectorInput[MachineId]] = None,
    ) -> "Session":
        return Session(self, self._sync.session(selector, machine=machine))

    async def list_machines(
        self,
        *,
        request_options: RequestOptions = RequestOptions(),
    ) -> List["Machine"]:
        return await self._invoke(
            self._sync.list_machines,
            request_options=request_options,
        )

    async def close(self) -> None:
        if self._closed:
            return
        if self._close_task is not None and self._close_task.done():
            # A failed cleanup is retryable. A successful one sets _closed.
            self._close_task = None
        if self._close_task is None:
            self._closing = True

            async def cleanup() -> None:
                try:
                    streams = tuple(self._streams)
                    if streams:
                        await asyncio.gather(
                            *(stream.cancel() for stream in streams),
                            return_exceptions=True,
                        )
                    loop = asyncio.get_running_loop()
                    await loop.run_in_executor(None, self._sync.close)
                    await loop.run_in_executor(
                        None,
                        functools.partial(self._executor.shutdown, wait=True),
                    )
                except BaseException:
                    self._closing = False
                    raise
                else:
                    self._closed = True
                    self._closing = False

            self._close_task = asyncio.create_task(cleanup())
        await _await_cleanup(self._close_task)

    async def __aenter__(self) -> "Client":
        return self

    async def __aexit__(
        self,
        _type: object,
        _value: object,
        _traceback: object,
    ) -> None:
        await self.close()

    async def _run_control(
        self,
        function: Callable[..., ValueT],
        args: tuple[Any, ...],
        kwargs: dict[str, Any],
        request_options: RequestOptions,
    ) -> ValueT:
        if self._closed or self._closing:
            raise RuntimeError("async cmux client is closed")
        if not isinstance(request_options, RequestOptions):
            raise TypeError("request_options must be RequestOptions")
        cancel_event = threading.Event()
        loop = asyncio.get_running_loop()
        future = loop.run_in_executor(
            self._executor,
            self._sync._invoke_with_request_options,
            function,
            args,
            kwargs,
            request_options,
            cancel_event,
        )
        try:
            # The worker owns a request that must be drained after cancellation.
            # Shield preserves that future while we signal cancellation below.
            await asyncio.shield(future)
            return future.result()
        except asyncio.CancelledError:
            cancel_event.set()
            try:
                await asyncio.shield(future)
            except BaseException:
                # Drain the worker result. The request cancellation exception
                # is intentionally hidden by the caller's asyncio cancellation.
                pass
            try:
                future.result()
            except BaseException:
                pass
            raise

    async def _run_internal(
        self,
        function: Callable[..., ValueT],
        *args: Any,
    ) -> ValueT:
        if self._closed:
            raise RuntimeError("async cmux client is closed")
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            self._executor,
            functools.partial(function, *args),
        )

    async def _invoke(
        self,
        function: Callable[..., ValueT],
        *args: Any,
        request_options: RequestOptions = RequestOptions(),
        **kwargs: Any,
    ) -> Any:
        value = await self._run_control(
            function,
            args,
            kwargs,
            request_options,
        )
        return self._wrap(value)

    def _register_stream(self, stream: ResourceStream[Any]) -> None:
        if self._closed or self._closing:
            raise RuntimeError("async cmux client is closed")
        self._streams.add(stream)

    def _unregister_stream(self, stream: ResourceStream[Any]) -> None:
        self._streams.discard(stream)

    def _wrap(self, value: Any) -> Any:
        if isinstance(value, SyncResourceStream):
            return ResourceStream(self, value)
        wrapper = _WRAPPERS.get(type(value))
        if wrapper is not None:
            return wrapper(self, value)
        if isinstance(value, SyncCreatedPath):
            return CreatedPath(
                value.kind,
                self._wrap(value.workspace),
                self._wrap(value.screen) if value.screen is not None else None,
                self._wrap(value.pane) if value.pane is not None else None,
                self._wrap(value.tab) if value.tab is not None else None,
                self._wrap(value.terminal)
                if value.terminal is not None
                else None,
                self._wrap(value.browser) if value.browser is not None else None,
            )
        if isinstance(value, MutationResult):
            return MutationResult(
                self._wrap(value.value),
                value.generation,
                value.revision,
                value.replayed,
            )
        if isinstance(value, CreationResolution):
            return CreationResolution(
                value.correlation_key,
                value.state,
                value.recovery,
                value.operation,
                value.idempotency_key,
                (
                    self._wrap(value.created_path)
                    if value.created_path is not None
                    else None
                ),
                value.generation,
                value.revision,
            )
        if isinstance(value, list):
            return [self._wrap(item) for item in value]
        return value


class _Handle:
    def __init__(self, owner: Client, handle: Any) -> None:
        self._owner = owner
        self._sync = handle

    @property
    def id(self):
        return self._sync.id

    @property
    def selector(self):
        return self._sync.selector

    @property
    def snapshot(self):
        return self._sync.snapshot

    async def refresh(
        self,
        *,
        request_options: RequestOptions = RequestOptions(),
    ):
        return await self._owner._invoke(
            self._sync.refresh,
            request_options=request_options,
        )

    def __getattr__(self, name: str):
        value = getattr(self._sync, name)
        if not callable(value):
            return value

        async def invoke(*args: Any, **kwargs: Any):
            request_options = kwargs.pop(
                "request_options",
                RequestOptions(),
            )
            unwrapped = [
                item._sync if isinstance(item, _Handle) else item for item in args
            ]
            return await self._owner._invoke(
                value,
                *unwrapped,
                request_options=request_options,
                **kwargs,
            )

        return invoke


class Machine(_Handle):
    def session(self, selector: SelectorInput[SessionId]) -> "Session":
        return Session(self._owner, self._sync.session(selector))


class Session(_Handle):
    @property
    def creation(self) -> "SessionCreation":
        return SessionCreation(self._owner, self._sync.creation)

    def workspace(self, selector: SelectorInput[WorkspaceId]) -> "Workspace":
        return Workspace(self._owner, self._sync.workspace(selector))

    def connected_client(
        self, selector: SelectorInput[ConnectedClientId]
    ) -> "ConnectedClient":
        return ConnectedClient(self._owner, self._sync.connected_client(selector))

    def pairing_request(
        self,
        selector: SelectorInput[PairingRequestId],
    ) -> "PairingRequest":
        return PairingRequest(self._owner, self._sync.pairing_request(selector))

    def terminal(self, selector: SelectorInput[TerminalId]) -> "Terminal":
        return Terminal(self._owner, self._sync.terminal(selector))

    def browser(self, selector: SelectorInput[BrowserId]) -> "Browser":
        return Browser(self._owner, self._sync.browser(selector))

    def sidebar_view(
        self, selector: SelectorInput[SidebarViewId]
    ) -> "SidebarView":
        return SidebarView(self._owner, self._sync.sidebar_view(selector))


class SessionCreation:
    def __init__(self, owner: Client, creation: SyncSessionCreation) -> None:
        self._owner = owner
        self._sync = creation

    async def resolve(
        self,
        correlation_key: str,
        *,
        request_options: RequestOptions = RequestOptions(),
    ):
        return await self._owner._invoke(
            self._sync.resolve,
            correlation_key,
            request_options=request_options,
        )


class Workspace(_Handle):
    def screen(self, selector: SelectorInput[ScreenId]) -> "Screen":
        return Screen(self._owner, self._sync.screen(selector))


class Screen(_Handle):
    def pane(self, selector: SelectorInput[PaneId]) -> "Pane":
        return Pane(self._owner, self._sync.pane(selector))


class Pane(_Handle):
    def tab(self, selector: SelectorInput[TabId]) -> "Tab":
        return Tab(self._owner, self._sync.tab(selector))


class Tab(_Handle):
    def terminal(self, selector: SelectorInput[TerminalId]) -> "Terminal":
        return Terminal(self._owner, self._sync.terminal(selector))

    def browser(self, selector: SelectorInput[BrowserId]) -> "Browser":
        return Browser(self._owner, self._sync.browser(selector))


class Terminal(_Handle):
    pass


class Browser(_Handle):
    pass


class ConnectedClient(_Handle):
    pass


class PairingRequest(_Handle):
    pass


class FrontendProjection(_Handle):
    pass


class Notification(_Handle):
    pass


class Agent(_Handle):
    pass


class SidebarView(_Handle):
    pass


_WRAPPERS = {
    SyncMachine: Machine,
    SyncSession: Session,
    SyncWorkspace: Workspace,
    SyncScreen: Screen,
    SyncPane: Pane,
    SyncTab: Tab,
    SyncTerminal: Terminal,
    SyncBrowser: Browser,
    SyncConnectedClient: ConnectedClient,
    SyncPairingRequest: PairingRequest,
    SyncFrontendProjection: FrontendProjection,
    SyncNotification: Notification,
    SyncAgent: Agent,
    SyncSidebarView: SidebarView,
}


__all__ = [
    "Agent",
    "Browser",
    "Client",
    "ConnectedClient",
    "CreatedPath",
    "FrontendProjection",
    "Machine",
    "Notification",
    "PairingRequest",
    "Pane",
    "ResourceStream",
    "Screen",
    "Session",
    "SidebarView",
    "Tab",
    "Terminal",
    "Workspace",
]
