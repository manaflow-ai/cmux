from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Generic, Literal, Type, TypeVar, Union


class ResourceId(str):
    """Validated opaque public resource ID."""

    PREFIX = ""

    def __new__(cls, value: str) -> "ResourceId":
        if not isinstance(value, str):
            raise TypeError(f"{cls.__name__} must be a string")
        expected = rf"{re.escape(cls.PREFIX)}_[0-9a-f]{{32}}"
        if re.fullmatch(expected, value) is None:
            raise ValueError(
                f"{cls.__name__} must be {cls.PREFIX}_ followed by "
                "32 lowercase hexadecimal characters"
            )
        return str.__new__(cls, value)


class MachineId(ResourceId):
    PREFIX = "machine"


class SessionId(ResourceId):
    PREFIX = "session"


class WorkspaceId(ResourceId):
    PREFIX = "ws"


class ScreenId(ResourceId):
    PREFIX = "screen"


class PaneId(ResourceId):
    PREFIX = "pane"


class TabId(ResourceId):
    PREFIX = "tab"


class TerminalId(ResourceId):
    PREFIX = "term"


class BrowserId(ResourceId):
    PREFIX = "browser"


class ConnectedClientId(ResourceId):
    PREFIX = "client"


class SplitId(ResourceId):
    PREFIX = "split"


class StreamId(ResourceId):
    PREFIX = "stream"


class NotificationId(ResourceId):
    PREFIX = "notification"


class AgentId(ResourceId):
    PREFIX = "agent"


class ProjectionId(ResourceId):
    PREFIX = "projection"


class PairingRequestId(ResourceId):
    PREFIX = "pairing"


class SidebarViewId(ResourceId):
    PREFIX = "sidebar_view"


IdT = TypeVar("IdT", bound=ResourceId)
SelectorKind = Literal["id", "current", "name"]


@dataclass(frozen=True)
class Selector(Generic[IdT]):
    """A tagged typed ID, current marker, or exact resource name."""

    kind: SelectorKind
    value: Union[IdT, str, None] = None

    @classmethod
    def by_id(cls, value: IdT) -> "Selector[IdT]":
        if not isinstance(value, ResourceId):
            raise TypeError("ID selectors require a typed resource ID")
        return cls("id", value)

    @classmethod
    def current(cls) -> "Selector[IdT]":
        return cls("current")

    @classmethod
    def name(cls, value: str) -> "Selector[IdT]":
        if not isinstance(value, str):
            raise TypeError("selector name must be a string")
        return cls("name", value)

    def encode(self) -> str:
        if self.kind == "id" and isinstance(self.value, ResourceId):
            return str(self.value)
        if self.kind == "current" and self.value is None:
            return "current"
        if self.kind == "name" and isinstance(self.value, str):
            return f"name:{self.value}"
        raise ValueError("invalid selector")


SelectorInput = Union[Selector[IdT], IdT]


def encode_selector(value: SelectorInput[IdT], expected: Type[IdT]) -> str:
    if isinstance(value, expected):
        return str(value)
    if isinstance(value, Selector):
        if value.kind == "id" and not isinstance(value.value, expected):
            raise TypeError(f"selector requires {expected.__name__}")
        return value.encode()
    raise TypeError(f"selector requires {expected.__name__} or Selector")


__all__ = [
    "AgentId",
    "BrowserId",
    "ConnectedClientId",
    "MachineId",
    "NotificationId",
    "PairingRequestId",
    "PaneId",
    "ProjectionId",
    "ResourceId",
    "ScreenId",
    "Selector",
    "SelectorInput",
    "SessionId",
    "SidebarViewId",
    "SplitId",
    "StreamId",
    "TabId",
    "TerminalId",
    "WorkspaceId",
]
