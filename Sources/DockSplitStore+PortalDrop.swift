import Bonsplit
import CmuxTerminal
import Foundation

/// Portal pane-drop routing for the Dock — the Dock equivalent of
/// `Workspace.portalPaneDropZone` / `performPortalPaneDrop`.
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
    func performPortalPaneDrop(
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
                destination: Self.externalDropDestination(for: zone, targetPane: paneId)
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

    private static func externalDropDestination(
        for zone: DropZone,
        targetPane paneId: PaneID
    ) -> BonsplitController.ExternalTabDropRequest.Destination {
        switch zone {
        case .center: return .insert(targetPane: paneId, targetIndex: nil)
        case .left: return .split(targetPane: paneId, orientation: .horizontal, insertFirst: true)
        case .right: return .split(targetPane: paneId, orientation: .horizontal, insertFirst: false)
        case .top: return .split(targetPane: paneId, orientation: .vertical, insertFirst: true)
        case .bottom: return .split(targetPane: paneId, orientation: .vertical, insertFirst: false)
        }
    }
}
