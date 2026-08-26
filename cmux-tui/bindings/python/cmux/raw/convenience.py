from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from ._generated.models import Id, LivePane, RenderRow, Screen, Tab, Tree, Workspace


@dataclass(frozen=True)
class SurfaceContext:
    """Generated workspace-tree models that contain one surface."""

    workspace: Workspace
    screen: Screen
    pane: LivePane
    tab: Tab


def find_surface(tree: Tree, surface: Id) -> Optional[SurfaceContext]:
    """Find a surface and return its workspace, screen, pane, and tab context."""

    for workspace in tree.workspaces:
        for screen in workspace.screens:
            for pane in screen.panes:
                if not isinstance(pane, LivePane):
                    continue
                for tab in pane.tabs:
                    if tab.surface == surface:
                        return SurfaceContext(workspace, screen, pane, tab)
    return None


def active_live_pty(tree: Tree) -> Optional[SurfaceContext]:
    """Return the strict active workspace/screen/pane/tab path when it is a live PTY.

    This function does not fall back to an inactive path when an active link is
    missing, the active-tab index is invalid, or the active tab is dead or a
    browser.
    """

    for workspace in tree.workspaces:
        if not workspace.active:
            continue
        for screen in workspace.screens:
            if not screen.active:
                continue
            pane = next(
                (
                    pane
                    for pane in screen.panes
                    if isinstance(pane, LivePane) and pane.id == screen.active_pane
                ),
                None,
            )
            if pane is None or not 0 <= pane.active_tab < len(pane.tabs):
                return None
            tab = pane.tabs[pane.active_tab]
            if tab.dead or tab.kind != "pty":
                return None
            return SurfaceContext(workspace, screen, pane, tab)
        return None
    return None


def render_row_text(row: RenderRow) -> str:
    """Return a render row's text with styling removed and spacing preserved."""

    return "".join(run.text for run in row.runs)


__all__ = [
    "SurfaceContext",
    "active_live_pty",
    "find_surface",
    "render_row_text",
]
