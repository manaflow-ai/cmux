import Bonsplit
import Foundation

extension Workspace {
    func portalPaneDropZone(
        tabId: UUID,
        sourcePaneId: UUID,
        targetPane paneId: PaneID,
        proposedZone: DropZone
    ) -> DropZone {
        let sourcePane = PaneID(id: sourcePaneId)
        let controller = bonsplitController(containingPane: paneId)
            ?? bonsplitController(containingPane: sourcePane)
            ?? bonsplitController
        guard sourcePane != paneId,
              let panelId = panelIdFromSurfaceId(TabID(uuid: tabId)),
              panels[panelId]?.panelType == .terminal else {
            return proposedZone
        }

        if proposedZone == .left,
           controller.adjacentPane(to: sourcePane, direction: .right) == paneId {
            return .center
        }
        if proposedZone == .right,
           controller.adjacentPane(to: sourcePane, direction: .left) == paneId {
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

        let destination: BonsplitController.ExternalTabDropRequest.Destination
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

        let destinationController = bonsplitController(containingPane: paneId) ?? bonsplitController
        return handleExternalTabDrop(BonsplitController.ExternalTabDropRequest(
            tabId: TabID(uuid: tabId),
            sourcePaneId: sourcePane,
            destination: destination
        ), destinationController: destinationController)
    }
}
