import CMUXLayout
import Foundation

extension Workspace {
    func portalPaneDropZone(
        tabId: UUID,
        sourcePaneId: UUID,
        targetPane paneId: PaneID,
        proposedZone: DropZone
    ) -> DropZone {
        let sourcePane = PaneID(id: sourcePaneId)
        guard sourcePane != paneId,
              layoutController.tab(SurfaceID(uuid: tabId))?.kind == SurfaceKind.terminal else {
            return proposedZone
        }

        if proposedZone == .left,
           layoutController.adjacentPane(to: sourcePane, direction: .right) == paneId {
            return .center
        }
        if proposedZone == .right,
           layoutController.adjacentPane(to: sourcePane, direction: .left) == paneId {
            return .center
        }
        return proposedZone
    }

    @discardableResult
    func performPortalPaneDrop(
        tabId: UUID,
        sourcePaneId: UUID,
        targetPane paneId: PaneID,
        zone: DropZone
    ) -> Bool {
        let sourcePane = PaneID(id: sourcePaneId)
        if zone == .center, sourcePane == paneId {
            return true
        }

        let destination: WorkspaceLayoutController.ExternalTabDropRequest.Destination
        switch zone {
        case .center:
            destination = .insert(targetPane: paneId, targetIndex: nil)
        case .left:
            destination = .split(targetPane: paneId, orientation: .horizontal, insertFirst: true)
        case .right:
            destination = .split(targetPane: paneId, orientation: .horizontal, insertFirst: false)
        case .top:
            destination = .split(targetPane: paneId, orientation: .vertical, insertFirst: true)
        case .bottom:
            destination = .split(targetPane: paneId, orientation: .vertical, insertFirst: false)
        }

        return handleExternalTabDrop(WorkspaceLayoutController.ExternalTabDropRequest(
            tabId: SurfaceID(uuid: tabId),
            sourcePaneId: sourcePane,
            destination: destination
        ))
    }
}
