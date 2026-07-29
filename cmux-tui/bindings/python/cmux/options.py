from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Mapping, Optional, Sequence, Tuple

from .ids import TerminalId
from .models import Command, Cursor, LayoutDocument, ProviderActionValue


Direction = Literal["left", "right", "up", "down"]
InitialContent = Literal["terminal", "empty"]


@dataclass(frozen=True)
class CreateMachineOptions:
    """Reserved for forward-compatible provider machine creation."""


@dataclass(frozen=True)
class CreateWorkspaceOptions:
    name: Optional[str] = None
    initial_content: InitialContent = "terminal"


@dataclass(frozen=True)
class CreateScreenOptions:
    name: Optional[str] = None


@dataclass(frozen=True)
class CreatePaneOptions:
    cwd: Optional[str] = None
    columns: Optional[int] = None
    rows: Optional[int] = None


@dataclass(frozen=True)
class SplitPaneOptions:
    direction: Direction
    ratio: Optional[float] = None
    cwd: Optional[str] = None
    columns: Optional[int] = None
    rows: Optional[int] = None


@dataclass(frozen=True)
class CreateTerminalOptions:
    cwd: Optional[str] = None
    name: Optional[str] = None
    columns: Optional[int] = None
    rows: Optional[int] = None


@dataclass(frozen=True)
class CreateBrowserOptions:
    url: str
    name: Optional[str] = None
    width_px: Optional[int] = None
    height_px: Optional[int] = None


@dataclass(frozen=True)
class RunOptions:
    command: Command
    name: Optional[str] = None
    columns: Optional[int] = None
    rows: Optional[int] = None


@dataclass(frozen=True)
class SessionEventsOptions:
    cursor: Optional[Cursor] = None


@dataclass(frozen=True)
class TerminalHistoryOptions:
    before: Optional[str] = None
    limit: Optional[int] = None
    styled: Optional[bool] = None


@dataclass(frozen=True)
class TerminalWaitOptions:
    pattern: str
    timeout_ms: Optional[int] = None


@dataclass(frozen=True)
class TerminalAttachOptions:
    columns: Optional[int] = None
    rows: Optional[int] = None
    read_only: Optional[bool] = None


@dataclass(frozen=True)
class BrowserAttachOptions:
    width_px: Optional[int] = None
    height_px: Optional[int] = None


@dataclass(frozen=True)
class LayoutApplyOptions:
    layout: LayoutDocument


@dataclass(frozen=True)
class KeyInputOptions:
    keys: Tuple[str, ...]

    @classmethod
    def from_sequence(cls, keys: Sequence[str]) -> "KeyInputOptions":
        return cls(tuple(keys))


@dataclass(frozen=True)
class TerminalMouseOptions:
    kind: str
    row: int
    column: int
    button: Optional[str] = None
    delta_rows: Optional[int] = None
    modifiers: Tuple[str, ...] = ()


@dataclass(frozen=True)
class BrowserMouseOptions:
    kind: str
    x_px: float
    y_px: float
    button: Optional[str] = None
    click_count: Optional[int] = None


@dataclass(frozen=True)
class ViewerSizeOptions:
    columns: int
    rows: int


@dataclass(frozen=True)
class BrowserViewerSizeOptions:
    width_px: int
    height_px: int


@dataclass(frozen=True)
class NotificationOptions:
    title: str
    body: str
    level: Optional[str] = None
    terminal_id: Optional[TerminalId] = None


@dataclass(frozen=True)
class AgentReportOptions:
    terminal_id: TerminalId
    state: str
    source: Literal["hook", "socket"]
    source_session: Optional[str] = None


@dataclass(frozen=True)
class ProviderActionOptions:
    parameters: Mapping[str, ProviderActionValue]


@dataclass(frozen=True)
class SidebarInputOptions:
    data_base64: str


@dataclass(frozen=True)
class SidebarResizeOptions:
    columns: int
    rows: int


@dataclass(frozen=True)
class SidebarEnsureOptions(SidebarResizeOptions):
    relaunch: Optional[bool] = None


__all__ = [
    "AgentReportOptions",
    "BrowserAttachOptions",
    "BrowserMouseOptions",
    "BrowserViewerSizeOptions",
    "CreateBrowserOptions",
    "CreateMachineOptions",
    "CreatePaneOptions",
    "CreateScreenOptions",
    "CreateTerminalOptions",
    "CreateWorkspaceOptions",
    "Direction",
    "InitialContent",
    "KeyInputOptions",
    "LayoutApplyOptions",
    "NotificationOptions",
    "ProviderActionOptions",
    "RunOptions",
    "SessionEventsOptions",
    "SidebarEnsureOptions",
    "SidebarInputOptions",
    "SidebarResizeOptions",
    "SplitPaneOptions",
    "TerminalAttachOptions",
    "TerminalHistoryOptions",
    "TerminalMouseOptions",
    "TerminalWaitOptions",
    "ViewerSizeOptions",
]
