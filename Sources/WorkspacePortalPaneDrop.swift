import Bonsplit
import Foundation
import CmuxWorkspaces

extension Workspace {
    func portalPaneDropZone(
        tabId: UUID,
        sourcePaneId: UUID,
        targetPane paneId: PaneID,
        proposedZone: DropZone
    ) -> DropZone {
        let sourcePane = PaneID(id: sourcePaneId)
        guard sourcePane != paneId,
              bonsplitController.tab(TabID(uuid: tabId))?.kind == SurfaceKind.terminal.rawValue else {
            return proposedZone
        }

        if proposedZone == .left,
           bonsplitController.adjacentPane(to: sourcePane, direction: .right) == paneId {
            return .center
        }
        if proposedZone == .right,
           bonsplitController.adjacentPane(to: sourcePane, direction: .left) == paneId {
            return .center
        }
        return proposedZone
    }

    @discardableResult
    func performPortalSurfaceDrop(
        tabId: UUID,
        sourcePaneId: UUID,
        targetPane paneId: PaneID,
        zone: DropZone
    ) -> Bool {
        let sourcePane = PaneID(id: sourcePaneId)
        if zone == .center, sourcePane == paneId {
            return true
        }

        return handleExternalTabDrop(BonsplitController.ExternalTabDropRequest(
            tabId: TabID(uuid: tabId),
            sourcePaneId: sourcePane,
            destination: PaneDropRouting.destination(
                targetPane: paneId,
                zone: zone
            )
        ))
    }
}
