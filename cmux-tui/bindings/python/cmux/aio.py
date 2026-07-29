from __future__ import annotations

import asyncio
import functools
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any, AsyncIterator, Callable, Generic, List, Optional, TypeVar

from ._protocol import ResourceStream as SyncResourceStream
from .ids import (
    BrowserId,
    ConnectedClientId,
    MachineId,
    PaneId,
    ProviderActionId,
    ProviderNoticeId,
    ProviderScopeId,
    ScreenId,
    SelectorInput,
    SessionId,
    SidebarViewId,
    TabId,
    TerminalId,
    WorkspaceId,
)
from .models import MutationResult, StreamItem
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
    ProviderAction as SyncProviderAction,
    ProviderNotice as SyncProviderNotice,
    ProviderScope as SyncProviderScope,
    Screen as SyncScreen,
    Session as SyncSession,
    SidebarView as SyncSidebarView,
    Tab as SyncTab,
    Terminal as SyncTerminal,
    Workspace as SyncWorkspace,
)


ValueT = TypeVar("ValueT")
_ITERATION_END = object()


def _next_or_end(stream: SyncResourceStream[ValueT]) -> Any:
    try:
        return next(stream)
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

    @property
    def id(self):
        return self._stream.id

    @property
    def end(self):
        return self._stream.end

    def __aiter__(self) -> "ResourceStream[ValueT]":
        return self

    async def __anext__(self) -> StreamItem[ValueT]:
        value = await self._owner._run(_next_or_end, self._stream)
        if value is _ITERATION_END:
            raise StopAsyncIteration
        return value

    async def cancel(self) -> None:
        await self._owner._run(self._stream.cancel)

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

    A canceled I/O task closes its underlying connection before returning
    cancellation, which unblocks the single worker and prevents leaked
    executor or reader threads.
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
            max_workers=1,
            thread_name_prefix="cmux-aio",
        )
        self._closed = False

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

    def provider_scope(
        self, selector: SelectorInput[ProviderScopeId]
    ) -> "ProviderScope":
        return ProviderScope(self, self._sync.provider_scope(selector))

    async def list_machines(self) -> List["Machine"]:
        return await self._invoke(self._sync.list_machines)

    async def create_machine(self, *args: Any, **kwargs: Any):
        return await self._invoke(self._sync.create_machine, *args, **kwargs)

    async def list_provider_scopes(self) -> List["ProviderScope"]:
        return await self._invoke(self._sync.list_provider_scopes)

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._sync.close()
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(
            None,
            functools.partial(self._executor.shutdown, wait=True),
        )

    async def __aenter__(self) -> "Client":
        return self

    async def __aexit__(
        self,
        _type: object,
        _value: object,
        _traceback: object,
    ) -> None:
        await self.close()

    async def _run(self, function: Callable[..., ValueT], *args: Any) -> ValueT:
        if self._closed:
            raise RuntimeError("async cmux client is closed")
        loop = asyncio.get_running_loop()
        future = loop.run_in_executor(
            self._executor,
            functools.partial(function, *args),
        )
        try:
            return await future
        except asyncio.CancelledError:
            self._closed = True
            self._sync.close()
            await loop.run_in_executor(
                None,
                functools.partial(self._executor.shutdown, wait=True),
            )
            raise

    async def _invoke(
        self,
        function: Callable[..., ValueT],
        *args: Any,
        **kwargs: Any,
    ) -> Any:
        value = await self._run(functools.partial(function, *args, **kwargs))
        return self._wrap(value)

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

    async def refresh(self):
        return await self._owner._invoke(self._sync.refresh)

    def __getattr__(self, name: str):
        value = getattr(self._sync, name)
        if not callable(value):
            return value

        async def invoke(*args: Any, **kwargs: Any):
            unwrapped = [
                item._sync if isinstance(item, _Handle) else item for item in args
            ]
            return await self._owner._invoke(value, *unwrapped, **kwargs)

        return invoke


class Machine(_Handle):
    def session(self, selector: SelectorInput[SessionId]) -> "Session":
        return Session(self._owner, self._sync.session(selector))


class Session(_Handle):
    def workspace(self, selector: SelectorInput[WorkspaceId]) -> "Workspace":
        return Workspace(self._owner, self._sync.workspace(selector))

    def connected_client(
        self, selector: SelectorInput[ConnectedClientId]
    ) -> "ConnectedClient":
        return ConnectedClient(self._owner, self._sync.connected_client(selector))

    def terminal(self, selector: SelectorInput[TerminalId]) -> "Terminal":
        return Terminal(self._owner, self._sync.terminal(selector))

    def browser(self, selector: SelectorInput[BrowserId]) -> "Browser":
        return Browser(self._owner, self._sync.browser(selector))

    def sidebar_view(
        self, selector: SelectorInput[SidebarViewId]
    ) -> "SidebarView":
        return SidebarView(self._owner, self._sync.sidebar_view(selector))


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


class ProviderScope(_Handle):
    def action(
        self, selector: SelectorInput[ProviderActionId]
    ) -> "ProviderAction":
        return ProviderAction(self._owner, self._sync.action(selector))

    def notice(
        self, selector: SelectorInput[ProviderNoticeId]
    ) -> "ProviderNotice":
        return ProviderNotice(self._owner, self._sync.notice(selector))


class ProviderAction(_Handle):
    pass


class ProviderNotice(_Handle):
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
    SyncProviderScope: ProviderScope,
    SyncProviderAction: ProviderAction,
    SyncProviderNotice: ProviderNotice,
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
    "ProviderAction",
    "ProviderNotice",
    "ProviderScope",
    "ResourceStream",
    "Screen",
    "Session",
    "SidebarView",
    "Tab",
    "Terminal",
    "Workspace",
]
