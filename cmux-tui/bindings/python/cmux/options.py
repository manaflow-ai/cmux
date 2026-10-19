from __future__ import annotations

import math
import threading
from dataclasses import dataclass
from typing import Literal, Optional, Sequence, Tuple

from .ids import TerminalId
from .models import Command, Cursor, LayoutDocument


Direction = Literal["left", "right", "up", "down"]
InitialContent = Literal["terminal", "empty"]


def _validate_correlation_key(value: Optional[str]) -> None:
    if value is None:
        return
    if not isinstance(value, str):
        raise TypeError("correlation_key must be a string")
    if not value or len(value.encode("utf-8")) > 128:
        raise ValueError(
            "correlation_key must contain 1 to 128 UTF-8 bytes"
        )


class CancellationToken:
    """Thread-safe cancellation signal for one or more SDK calls."""

    def __init__(self) -> None:
        self._event = threading.Event()

    def cancel(self) -> None:
        self._event.set()

    @property
    def is_cancelled(self) -> bool:
        return self._event.is_set()


@dataclass(frozen=True)
class RequestOptions:
    """Local deadline and cancellation policy for one SDK call."""

    timeout: Optional[float] = None
    cancellation: Optional[CancellationToken] = None

    def __post_init__(self) -> None:
        if self.timeout is not None and (
            isinstance(self.timeout, bool)
            or not isinstance(self.timeout, (int, float))
        ):
            raise TypeError("request timeout must be a number")
        if self.timeout is not None and (
            not math.isfinite(self.timeout) or self.timeout <= 0
        ):
            raise ValueError("request timeout must be finite and greater than zero")
        if self.cancellation is not None and not isinstance(
            self.cancellation,
            CancellationToken,
        ):
            raise TypeError("request cancellation must be a CancellationToken")


@dataclass(frozen=True)
class CreateWorkspaceOptions:
    name: Optional[str] = None
    initial_content: InitialContent = "terminal"
    correlation_key: Optional[str] = None

    def __post_init__(self) -> None:
        _validate_correlation_key(self.correlation_key)


@dataclass(frozen=True)
class CreateScreenOptions:
    name: Optional[str] = None
    correlation_key: Optional[str] = None

    def __post_init__(self) -> None:
        _validate_correlation_key(self.correlation_key)


@dataclass(frozen=True)
class CreatePaneOptions:
    cwd: Optional[str] = None
    columns: Optional[int] = None
    rows: Optional[int] = None
    correlation_key: Optional[str] = None

    def __post_init__(self) -> None:
        _validate_correlation_key(self.correlation_key)


@dataclass(frozen=True)
class SplitPaneOptions:
    direction: Direction
    ratio: Optional[float] = None
    cwd: Optional[str] = None
    columns: Optional[int] = None
    rows: Optional[int] = None
    correlation_key: Optional[str] = None
    viewport_width: Optional[float] = None

    def __post_init__(self) -> None:
        _validate_correlation_key(self.correlation_key)


@dataclass(frozen=True)
class CreateTerminalOptions:
    cwd: Optional[str] = None
    name: Optional[str] = None
    columns: Optional[int] = None
    rows: Optional[int] = None
    correlation_key: Optional[str] = None

    def __post_init__(self) -> None:
        _validate_correlation_key(self.correlation_key)


@dataclass(frozen=True)
class CreateBrowserOptions:
    url: str
    name: Optional[str] = None
    width_px: Optional[int] = None
    height_px: Optional[int] = None
    correlation_key: Optional[str] = None

    def __post_init__(self) -> None:
        _validate_correlation_key(self.correlation_key)


@dataclass(frozen=True)
class RunOptions:
    command: Command
    name: Optional[str] = None
    columns: Optional[int] = None
    rows: Optional[int] = None
    cwd: Optional[str] = None
    correlation_key: Optional[str] = None

    def __post_init__(self) -> None:
        _validate_correlation_key(self.correlation_key)


@dataclass(frozen=True)
class SessionEventsOptions:
    cursor: Optional[Cursor] = None


@dataclass(frozen=True)
class JournalSubjectFilter:
    kind: Optional[str] = None
    id: Optional[str] = None


@dataclass(frozen=True)
class JournalRegexFilter:
    pattern: str
    field: Literal["kind", "subjects", "payload", "record", "terminal_output"] = "record"
    case_sensitive: bool = True


@dataclass(frozen=True)
class JournalFilter:
    kinds: Optional[Sequence[str]] = None
    classes: Optional[Sequence[str]] = None
    subjects: Optional[Sequence[JournalSubjectFilter]] = None
    max_sensitivity: Optional[Literal["public", "metadata", "sensitive"]] = None
    regex: Optional[JournalRegexFilter] = None


@dataclass(frozen=True)
class SessionJournalOptions:
    cursor: Optional[Cursor] = None
    start: Optional[Literal["tail", "beginning"]] = None
    follow: Optional[bool] = None
    filter: Optional[JournalFilter] = None


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
    pointer_frame_seq: int
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
    "CancellationToken",
    "CreateBrowserOptions",
    "CreatePaneOptions",
    "CreateScreenOptions",
    "CreateTerminalOptions",
    "CreateWorkspaceOptions",
    "Direction",
    "InitialContent",
    "KeyInputOptions",
    "LayoutApplyOptions",
    "NotificationOptions",
    "RequestOptions",
    "RunOptions",
    "SessionEventsOptions",
    "JournalFilter",
    "JournalRegexFilter",
    "JournalSubjectFilter",
    "SessionJournalOptions",
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
