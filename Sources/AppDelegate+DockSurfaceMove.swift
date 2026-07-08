import AppKit
import Bonsplit
import CmuxTerminal

/// Cross-container live-panel moves involving the Dock.
///
/// The main split area moves panels between workspaces through
/// `moveSurface`/`moveBonsplitTab`. The Dock keeps its panels in a separate
/// `DockSplitStore` registry, so these helpers bridge the two: a tab dragged
/// from the main area onto a Dock (or between Docks) routes through
/// `moveSurfaceIntoDock`, and a tab dragged from a Dock onto the main area
/// routes through `moveBonsplitTab`'s Dock fallback into
/// `moveDockSurfaceToWorkspace`. Both reuse the existing
/// `DetachedSurfaceTransfer` currency so the live process/surface is preserved.
extension AppDelegate {
    /// Where a Bonsplit tab currently lives, for cross-container surface moves.
    enum ContainerSurfaceLocation {
        case workspace(windowId: UUID, workspace: Workspace, panelId: UUID, manager: TabManager)
        case dock(DockSplitStore, panelId: UUID)
    }

    /// Locates a Bonsplit tab across workspace pane trees and every created Dock.
    /// Returns nil when no live surface owns the id.
    func locateContainerSurface(tabId: UUID) -> ContainerSurfaceLocation? {
        if let located = locateBonsplitSurface(tabId: tabId),
           let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) {
            return .workspace(
                windowId: located.windowId,
                workspace: workspace,
                panelId: located.panelId,
                manager: located.tabManager
            )
        }
        if let dockSource = locateDockSurface(tabId: tabId) {
            return .dock(dockSource.dock, panelId: dockSource.panelId)
        }
        return nil
    }

    /// Whether the right sidebar (Files / Find / Dock) currently owns input
    /// focus in `workspace`'s window. Lets the workspace's imperative terminal
    /// portal active-state reconcile honor the same focus-exclusivity gate the
    /// SwiftUI render path uses, so a background layout reconcile cannot
    /// re-activate a main terminal while the sidebar is focused.
    func rightSidebarOwnsInputFocus(for workspace: Workspace) -> Bool {
        guard let manager = workspace.owningTabManager,
              let context = mainWindowContexts.values.first(where: { $0.tabManager === manager }) else {
            return false
        }
        return context.fileExplorerState?.rightSidebarOwnsInputFocus ?? false
    }

    /// Finds the Dock (any window's Dock or any workspace's local Dock) that
    /// owns a pane. Used by the portal drop target to route a tab dropped on a
    /// Dock pane to the Dock's own controller instead of the workspace's.
    func dockForPane(_ paneId: PaneID) -> DockSplitStore? {
        if let windowDock = windowDockContainingPane(paneId.id) {
            return windowDock
        }
        for context in mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                if let dock = workspace._dockSplit, dock.containsPane(paneId.id) {
                    return dock
                }
            }
        }
        return nil
    }

    /// Finds a Dock-hosted source for a Bonsplit tab (ignoring workspace panes).
    /// Used by `moveBonsplitTab` to route a Dock→main-area drop.
    func locateDockSurface(tabId: UUID) -> (dock: DockSplitStore, panelId: UUID)? {
        let bonsplitTabId = TabID(uuid: tabId)
        // Per-window Docks first (they have no owning workspace), then each
        // workspace's local Dock.
        for windowDock in existingWindowDocks {
            if let panel = windowDock.panel(for: bonsplitTabId) {
                return (windowDock, panel.id)
            }
        }
        for context in mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                guard let dock = workspace._dockSplit,
                      let panel = dock.panel(for: bonsplitTabId) else { continue }
                return (dock, panel.id)
            }
        }
        return nil
    }

    /// Moves a live panel from any container INTO `destinationDock`. Backs the
    /// Dock's `onExternalTabDrop`, so it handles main-area→Dock and Dock→Dock.
    @discardableResult
    func moveSurfaceIntoDock(
        sourceTabId: UUID,
        destinationDock: DockSplitStore,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        guard let source = locateContainerSurface(tabId: sourceTabId) else { return false }
        let shouldPreserveSourceWorkspace = shouldPreserveSourceWorkspaceAfterDockMove(
            source,
            destinationDock: destinationDock
        )

        let target = resolveDockDropDestination(destination)
        guard destinationDock.containsPane(target.pane.id) else { return false }

        guard let detached = detachSurfaceFromContainer(source) else { return false }

        guard destinationDock.attachDetachedSurface(
            detached,
            inPane: target.pane,
            atIndex: target.index,
            focus: true
        ) != nil else {
            reattachSurfaceToContainer(detached, source)
            return false
        }

        if let split = target.split,
           let movedTabId = destinationDock.surfaceId(forPanelId: detached.panelId) {
            // Not wrapped in `withProgrammaticDockSplit`: this moves the just-attached
            // tab out of `target.pane` to form the split, which can leave `target.pane`
            // holding only Bonsplit's placeholder "Empty" tab (when it was empty before
            // the drop). Letting `didSplitPane` run repairs that placeholder-only pane
            // into a real terminal (and is a no-op when the pane still has a surface).
            _ = destinationDock.bonsplitController.splitPane(
                target.pane,
                orientation: split.orientation,
                movingTab: movedTabId,
                insertFirst: split.insertFirst
            )
        }

        // The surface was attached into the Dock with focus, so record Dock focus
        // ownership. Without this, `rightSidebarOwnsInputFocus` stays false and the
        // focus-exclusivity gate would treat the just-dropped Dock terminal as
        // inactive (and the main pane would keep focus) even though the drop
        // requested focus. Resolve the destination Dock's OWN window rather than
        // the global key window: during a cross-window drag the source window can
        // still be key, which would publish focus to the wrong window's state.
        let destinationDockWindow = dockReferenceTabManager(for: destinationDock)
            .flatMap { windowId(for: $0) }
            .flatMap { mainWindow(for: $0) }
        destinationDock.noteKeyboardFocusIntent(
            window: destinationDockWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        )

        cleanupEmptyContainerAfterMove(
            source,
            preserveSourceWorkspace: shouldPreserveSourceWorkspace
        )
        return true
    }

    /// Moves a live Dock panel into a workspace pane tree. Backs the Dock→main
    /// drop path routed from `moveBonsplitTab`.
    @discardableResult
    func moveDockSurfaceToWorkspace(
        sourceDock: DockSplitStore,
        panelId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID?,
        targetIndex: Int?,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)?,
        focus: Bool,
        focusWindow: Bool
    ) -> Bool {
        guard let destinationManager = tabManagerFor(tabId: targetWorkspaceId),
              let destinationWorkspace = destinationManager.tabs.first(where: { $0.id == targetWorkspaceId }) else {
            return false
        }
        let resolvedPane = targetPane.flatMap { pane in
            destinationWorkspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
        } ?? destinationWorkspace.bonsplitController.focusedPaneId
            ?? destinationWorkspace.bonsplitController.allPaneIds.first
        guard let resolvedPane else { return false }

        let sourcePane = sourceDock.paneId(forPanelId: panelId)
        guard let detached = sourceDock.detachSurface(panelId: panelId) else { return false }
        // Leaving the Dock: a terminal rejoins workspace focus routing so portal
        // layering and focus cycling stop treating it as a Dock surface.
        (detached.panel as? TerminalPanel)?.surface.setFocusPlacement(.workspace)

        guard destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: resolvedPane,
            atIndex: targetIndex,
            focus: focus
        ) != nil else {
            // Roll the panel back into the Dock unchanged.
            (detached.panel as? TerminalPanel)?.surface.setFocusPlacement(.rightSidebarDock)
            if let rollbackPane = sourcePane ?? sourceDock.bonsplitController.allPaneIds.first {
                _ = sourceDock.attachDetachedSurface(detached, inPane: rollbackPane, focus: false)
            }
            return false
        }

        if let splitTarget, let movedTabId = destinationWorkspace.surfaceIdFromPanelId(panelId) {
            _ = destinationWorkspace.bonsplitController.splitPane(
                resolvedPane,
                orientation: splitTarget.orientation,
                movingTab: movedTabId,
                insertFirst: splitTarget.insertFirst
            )
        }

        if focus {
            if focusWindow, let destinationWindowId = windowId(for: destinationManager) {
                _ = focusMainWindow(windowId: destinationWindowId)
            }
            destinationManager.focusTab(targetWorkspaceId, surfaceId: panelId, suppressFlash: true)
        }
        return true
    }

    /// Moves a live Dock panel into a freshly created workspace (the Dock tab
    /// "Move to → New Workspace" action). Mirrors `moveSurfaceToNewWorkspace`
    /// but detaches from the Dock and rejoins workspace focus routing.
    @discardableResult
    func moveDockSurfaceToNewWorkspace(
        sourceDock: DockSplitStore,
        panelId: UUID,
        focus: Bool = true,
        focusWindow: Bool = false
    ) -> Bool {
        // A window Dock resolves its owning window; a Workspace Dock resolves
        // that workspace's window (see `dockReferenceTabManager`).
        guard let manager = dockReferenceTabManager(for: sourceDock) else { return false }
        let sourcePane = sourceDock.paneId(forPanelId: panelId)
        guard let detached = sourceDock.detachSurface(panelId: panelId) else { return false }
        (detached.panel as? TerminalPanel)?.surface.setFocusPlacement(.workspace)

        guard manager.addWorkspace(fromDetachedSurface: detached, select: focus) != nil else {
            // Creation failed — roll the panel back into the Dock unchanged.
            (detached.panel as? TerminalPanel)?.surface.setFocusPlacement(.rightSidebarDock)
            if let rollbackPane = sourcePane ?? sourceDock.bonsplitController.allPaneIds.first {
                _ = sourceDock.attachDetachedSurface(detached, inPane: rollbackPane, focus: false)
            }
            return false
        }

        if focus, focusWindow, let destinationWindowId = windowId(for: manager) {
            _ = focusMainWindow(windowId: destinationWindowId)
        }
        return true
    }

    private func resolveDockDropDestination(
        _ destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> (pane: PaneID, index: Int?, split: (orientation: SplitOrientation, insertFirst: Bool)?) {
        switch destination {
        case .insert(let pane, let index):
            return (pane, index, nil)
        case .split(let pane, let orientation, let insertFirst):
            return (pane, nil, (orientation, insertFirst))
        }
    }

    private func shouldPreserveSourceWorkspaceAfterDockMove(
        _ source: ContainerSurfaceLocation,
        destinationDock: DockSplitStore
    ) -> Bool {
        guard case .workspace(let sourceWindowId, let workspace, _, let manager) = source,
              workspace.panels.count == 1 else {
            return false
        }

        switch destinationDock.scope {
        case .workspace:
            return destinationDock.workspaceId == workspace.id
        case .global:
            return destinationDock.workspaceId == sourceWindowId && manager.tabs.count == 1
        }
    }

    private func detachSurfaceFromContainer(
        _ source: ContainerSurfaceLocation
    ) -> Workspace.DetachedSurfaceTransfer? {
        switch source {
        case .workspace(_, let workspace, let panelId, _):
            return workspace.detachSurface(panelId: panelId)
        case .dock(let dock, let panelId):
            return dock.detachSurface(panelId: panelId)
        }
    }

    /// Best-effort rollback used when the destination attach fails: returns the
    /// live panel to its source container's focused/first pane and restores the
    /// source's focus-routing placement.
    private func reattachSurfaceToContainer(
        _ detached: Workspace.DetachedSurfaceTransfer,
        _ source: ContainerSurfaceLocation
    ) {
        switch source {
        case .workspace(_, let workspace, _, _):
            (detached.panel as? TerminalPanel)?.surface.setFocusPlacement(.workspace)
            rollbackDetachedSurface(detached, to: workspace, sourcePane: nil, sourceIndex: nil, focus: true)
        case .dock(let dock, _):
            (detached.panel as? TerminalPanel)?.surface.setFocusPlacement(.rightSidebarDock)
            if let pane = dock.bonsplitController.focusedPaneId ?? dock.bonsplitController.allPaneIds.first {
                _ = dock.attachDetachedSurface(detached, inPane: pane, focus: false)
            }
        }
    }

    private func cleanupEmptyContainerAfterMove(
        _ source: ContainerSurfaceLocation,
        preserveSourceWorkspace: Bool = false
    ) {
        switch source {
        case .workspace(let windowId, let workspace, _, let manager):
            if preserveSourceWorkspace {
                preserveEmptySourceWorkspaceAfterSurfaceMove(sourceWorkspace: workspace)
            } else {
                cleanupEmptySourceWorkspaceAfterSurfaceMove(
                    sourceWorkspace: workspace,
                    sourceManager: manager,
                    sourceWindowId: windowId
                )
            }
        case .dock:
            // The Dock auto-closes emptied panes (autoCloseEmptyPanes) and keeps
            // an empty root pane, so there is nothing to tear down.
            break
        }
    }

    private func preserveEmptySourceWorkspaceAfterSurfaceMove(sourceWorkspace: Workspace) {
        guard sourceWorkspace.panels.isEmpty else { return }
        _ = sourceWorkspace.createReplacementTerminalPanel()
        sourceWorkspace.scheduleTerminalGeometryReconcile()
    }
}
