import Bonsplit
import CmuxWorkspaces
import CoreGraphics
import Foundation

/// The window-side host for the CmuxWorkspaces ``SessionRestoreCoordinator``:
/// the live surface-id → panel-id map the snapshot transform reads, and the
/// single Bonsplit divider mutation the restore-side divider apply issues.
///
/// `surfaceIdToPanelId` is already witnessed by `Workspace`'s like-named
/// computed property (it forwards to the pane-tree sub-model), so one
/// declaration satisfies the seam read. `applySessionDividerPosition(_:forSplit:)`
/// forwards to `bonsplitController.setDividerPosition(_:forSplit:fromExternal:)`
/// with `fromExternal: true`, exactly as the legacy
/// `applySessionDividerPositions` body did; the controller treats an unknown
/// split id as a no-op, preserving the legacy optional handling.
extension Workspace: WorkspaceSessionRestoreHosting {
    func sessionFullWidthTabMode(forPaneId paneId: UUID) -> Bool {
        bonsplitController.isFullWidthTabMode(inPane: PaneID(id: paneId))
    }

    func applySessionDividerPosition(_ position: CGFloat, forSplit splitID: UUID) {
        _ = bonsplitController.setDividerPosition(
            position,
            forSplit: splitID,
            fromExternal: true
        )
    }
}
