import Bonsplit
import CmuxWorkspaces
import Foundation

/// Workspace todo pane factory: creates the `WorkspaceTodoPanel` surface and
/// the one-per-workspace open-or-focus entry point every caller (checklist
/// popover footer, command palette, CLI `cmux todo open`, socket
/// `workspace.todo.open`, session restore) funnels through. Mirrors the
/// markdown surface factory; lives in its own file because `Workspace.swift`
/// sits at its file-length budget.
extension Workspace {
    @discardableResult
    func newWorkspaceTodoSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> WorkspaceTodoPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let todoPanel = WorkspaceTodoPanel(workspace: self)
        panels[todoPanel.id] = todoPanel
        panelTitles[todoPanel.id] = todoPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: todoPanel.displayTitle,
            icon: todoPanel.displayIcon,
            kind: SurfaceKind.todo.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: todoPanel.id)
            panelTitles.removeValue(forKey: todoPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: todoPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            todoPanel.id,
            paneId: paneId,
            kind: SurfaceKind.todo.rawValue,
            origin: "todo_tab",
            focused: shouldFocusNewTab
        )
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: todoPanel.id,
                previousHostedView: previousHostedView
            )
        }

        return todoPanel
    }

    /// One todo pane per workspace: focuses the existing pane when present,
    /// otherwise creates one in `paneId`.
    @discardableResult
    func openOrFocusWorkspaceTodoSurface(
        inPane paneId: PaneID,
        focus: Bool = true
    ) -> WorkspaceTodoPanel? {
        for (existingId, panel) in panels {
            guard let todoPanel = panel as? WorkspaceTodoPanel else { continue }
            if focus {
                focusPanel(existingId)
            }
            return todoPanel
        }
        return newWorkspaceTodoSurface(inPane: paneId, focus: focus)
    }
}
