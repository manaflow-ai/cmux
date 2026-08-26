import Bonsplit
import CmuxTerminal
import CmuxWorkspaces
import Foundation

/// Portal pane-drop routing for the Dock — the Dock equivalent of
/// `Workspace.portalPaneDropZone` / `performPortalSurfaceDrop`.
///
/// Dock terminals are portal-hosted and share `PaneDropTargetView` with the
/// main area. Without this, every tab dropped onto a Dock pane was routed to
/// the owning *workspace's* controller (so a Dock drag-to-split landed in the
/// main split area). `PaneDropTargetView` now diverts tab drops whose target
/// pane belongs to a Dock here instead.
extension DockSplitStore {
    /// Mirrors `Workspace.portalPaneDropZone`: collapse an edge drop that targets
    /// the source pane's immediate neighbour to a center insert (avoids creating
    /// a redundant split when re-docking adjacent panes).
    func portalPaneDropZone(
        tabId: UUID,
        sourcePaneId: UUID,
        targetPane paneId: PaneID,
        proposedZone: DropZone
    ) -> DropZone {
        let sourcePane = PaneID(id: sourcePaneId)
        // Only collapse an adjacent-pane edge drop to a center insert for terminal
        // tabs, matching `Workspace.portalPaneDropZone`. Browser tabs must keep the
        // edge zone so dragging a browser onto an adjacent pane's shared edge still
        // creates a split. (Dock tab kinds are the raw "terminal"/"browser" strings.)
        guard sourcePane != paneId,
              containsPane(sourcePane.id),
              bonsplitController.tab(TabID(uuid: tabId))?.kind == "terminal" else { return proposedZone }
        if proposedZone == .left, bonsplitController.adjacentPane(to: sourcePane, direction: .right) == paneId {
            return .center
        }
        if proposedZone == .right, bonsplitController.adjacentPane(to: sourcePane, direction: .left) == paneId {
            return .center
        }
        return proposedZone
    }

    /// Performs a tab drop targeting a Dock pane.
    /// - Internal drag (source pane is in this Dock): move or split within the
    ///   Dock's own controller, so drag-to-split stays in the Dock.
    /// - External drag (source is the main area or another Dock): route through
    ///   `moveSurfaceIntoDock` so the live panel transfers in.
    @discardableResult
    func performPortalSurfaceDrop(
        tabId: UUID,
        sourcePaneId: UUID,
        targetPane paneId: PaneID,
        zone: DropZone
    ) -> Bool {
        let sourcePane = PaneID(id: sourcePaneId)

        guard containsPane(sourcePane.id) else {
            return AppDelegate.shared?.moveSurfaceIntoDock(
                sourceTabId: tabId,
                destinationDock: self,
                destination: PaneDropRouting.destination(
                    targetPane: paneId,
                    zone: zone
                )
            ) ?? false
        }

        // Internal Dock drag. A center drop onto the source pane is a no-op.
        if zone == .center, sourcePane == paneId { return true }
        let movedTab = TabID(uuid: tabId)
        let didMove: Bool
        switch zone {
        case .center:
            didMove = bonsplitController.moveTab(movedTab, toPane: paneId)
        case .left:
            didMove = bonsplitController.splitPane(paneId, orientation: .horizontal, movingTab: movedTab, insertFirst: true) != nil
        case .right:
            didMove = bonsplitController.splitPane(paneId, orientation: .horizontal, movingTab: movedTab, insertFirst: false) != nil
        case .top:
            didMove = bonsplitController.splitPane(paneId, orientation: .vertical, movingTab: movedTab, insertFirst: true) != nil
        case .bottom:
            didMove = bonsplitController.splitPane(paneId, orientation: .vertical, movingTab: movedTab, insertFirst: false) != nil
        }
        if didMove {
            scheduleDockPortalReconcile(reason: "dock.portalPaneDrop")
        }
        return didMove
    }

    /// Creates a restore-aware Vault terminal in the requested Dock position.
    func performPortalVaultSessionDrop(
        entry: SessionEntry,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        guard let launch = entry.resumeLaunch else { return false }
        switch destination {
        case .insert(let paneId, _):
            return newSurface(
                kind: .terminal,
                inPane: paneId,
                workingDirectory: launch.workingDirectory,
                initialInput: launch.initialInput,
                startupRestoreAgent: launch.startupRestoreAgent,
                focus: true
            ) != nil
        case .split(let paneId, let orientation, let insertFirst):
            let sourcePanelId = selectedPanelForPaneDrop(in: paneId)?.panelId
            return newSplit(
                kind: .terminal,
                orientation: orientation,
                insertFirst: insertFirst,
                sourcePanelId: sourcePanelId,
                workingDirectory: launch.workingDirectory,
                initialInput: launch.initialInput,
                startupRestoreAgent: launch.startupRestoreAgent,
                focus: true
            ) != nil
        }
    }

    /// Opens Finder files in the Dock-owned split tree. A file drop must never
    /// escape into the currently selected workspace merely because the Dock is
    /// presented alongside it.
    func handleExternalFileDrop(
        _ request: BonsplitController.ExternalFileDropRequest
    ) -> Bool {
        let filePaths = request.urls
            .filter(\.isFileURL)
            .map(\.path)
        guard !filePaths.isEmpty else { return false }

        switch request.destination {
        case .insert(let paneId, let index):
            return !openFilePreviewSurfaces(
                inPane: paneId,
                filePaths: filePaths,
                focus: true,
                targetIndex: index
            ).isEmpty

        case .split(let sourcePaneId, let orientation, let insertFirst):
            let remainingPaths = Array(filePaths.dropFirst())
            guard let firstPath = filePaths.first,
                  let splitResult = splitPaneWithFilePreview(
                      targetPane: sourcePaneId,
                      orientation: orientation,
                      insertFirst: insertFirst,
                      filePath: firstPath,
                      focus: remainingPaths.isEmpty
                  ) else {
                return false
            }
            guard !remainingPaths.isEmpty else { return true }
            let remainingPanels = openFilePreviewSurfaces(
                inPane: splitResult.pane,
                filePaths: remainingPaths,
                focus: true
            )
            if remainingPanels.isEmpty {
                focusPanelFromDockInteraction(splitResult.panel.id, window: nil)
            }
            return true
        }
    }

    /// Opens file-preview tabs in one already-validated Dock pane.
    @discardableResult
    func openFilePreviewSurfaces(
        inPane paneId: PaneID,
        filePaths: [String],
        focus: Bool,
        targetIndex: Int? = nil
    ) -> [FilePreviewPanel] {
        guard containsPane(paneId.id) else { return [] }
        let previousFocus = focusedDockPaneSelection()
        let openedPanels = withNewTabZoomPolicy(inPane: paneId, applyPolicy: focus) {
            var nextIndex = targetIndex
            var panels: [FilePreviewPanel] = []
            for filePath in filePaths {
                guard let panel = newFilePreviewSurfaceInValidatedPane(
                    inPane: paneId,
                    filePath: filePath,
                    targetIndex: nextIndex
                ) else {
                    continue
                }
                panels.append(panel)
                if let index = nextIndex {
                    nextIndex = index + 1
                }
            }
            return panels.isEmpty ? nil : panels
        } ?? []
        if focus, let finalPanel = openedPanels.last {
            focusPanelFromDockInteraction(finalPanel.id, window: nil)
        } else {
            restoreDockPaneSelection(previousFocus)
        }
        return openedPanels
    }

    /// Creates one file-preview tab and preserves or moves Dock focus as requested.
    @discardableResult
    func newFilePreviewSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool,
        targetIndex: Int? = nil
    ) -> FilePreviewPanel? {
        guard containsPane(paneId.id) else { return nil }
        let previousFocus = focusedDockPaneSelection()
        guard let panel = newFilePreviewSurfaceInValidatedPane(
            inPane: paneId,
            filePath: filePath,
            targetIndex: targetIndex
        ) else {
            restoreDockPaneSelection(previousFocus)
            return nil
        }
        if focus {
            focusPanel(panel.id)
        } else {
            restoreDockPaneSelection(previousFocus)
        }
        return panel
    }

    /// Creates one preview without performing a separate pane lookup or focus change.
    private func newFilePreviewSurfaceInValidatedPane(
        inPane paneId: PaneID,
        filePath: String,
        targetIndex: Int?
    ) -> FilePreviewPanel? {
        let panel = FilePreviewPanel(workspaceId: workspaceId, filePath: filePath)
        panels[panel.id] = panel
        guard let tabId = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: RenderableSystemSymbol.resolvedSurfaceTabIcon(panel.displayIcon),
            kind: SurfaceKind.filePreview.rawValue,
            isDirty: panel.isDirty,
            isPinned: false,
            inPane: paneId
        ) else {
            discardPanelOwnershipAndClose(panelId: panel.id)
            return nil
        }
        bindSurface(tabId, toPanelId: panel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(tabId, toIndex: targetIndex)
        }
        installSubscription(for: panel)
        recordExplicitPanelCreation()
        return panel
    }

    /// Creates the first preview in a new pane and returns that exact pane.
    private func splitPaneWithFilePreview(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String,
        focus: Bool
    ) -> (panel: FilePreviewPanel, pane: PaneID)? {
        guard containsPane(paneId.id) else { return nil }
        let panel = FilePreviewPanel(workspaceId: workspaceId, filePath: filePath)
        let tab = Bonsplit.Tab(
            title: panel.displayTitle,
            icon: RenderableSystemSymbol.resolvedSurfaceTabIcon(panel.displayIcon),
            kind: SurfaceKind.filePreview.rawValue,
            isDirty: panel.isDirty,
            isPinned: false
        )
        panels[panel.id] = panel
        bindSurface(tab.id, toPanelId: panel.id)
        let newPane = withProgrammaticDockSplit {
            bonsplitController.splitPane(
                paneId,
                orientation: orientation,
                withTab: tab,
                insertFirst: insertFirst
            )
        }
        guard let newPane else {
            discardPanelOwnershipAndClose(panelId: panel.id)
            return nil
        }
        installSubscription(for: panel)
        recordExplicitPanelCreation()
        if focus {
            focusPanelFromDockInteraction(panel.id, window: nil)
        }
        return (panel, newPane)
    }
}
