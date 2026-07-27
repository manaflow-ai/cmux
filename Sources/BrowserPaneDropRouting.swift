import AppKit
import Bonsplit

enum BrowserPaneDropRouting {
    static func zone(for location: CGPoint, in size: CGSize, topChromeHeight: CGFloat = 0) -> DropZone {
        PaneDropRouting.zone(for: location, in: size, topChromeHeight: topChromeHeight)
    }

    static func overlayFrame(for zone: DropZone, in size: CGSize, topChromeHeight: CGFloat = 0) -> CGRect {
        PaneDropRouting.compactOverlayFrame(for: zone, in: size, topChromeHeight: topChromeHeight)
    }

    static func action(
        for transfer: BrowserPaneDragTransfer,
        target: BrowserPaneDropContext,
        zone: DropZone
    ) -> BrowserPaneDropAction? {
        if zone == .center, transfer.sourcePaneId == target.paneId.id {
            return .noOp
        }

        let splitTarget: BrowserPaneSplitTarget?
        switch zone {
        case .center:
            splitTarget = nil
        case .left:
            splitTarget = BrowserPaneSplitTarget(orientation: .horizontal, insertFirst: true)
        case .right:
            splitTarget = BrowserPaneSplitTarget(orientation: .horizontal, insertFirst: false)
        case .top:
            splitTarget = BrowserPaneSplitTarget(orientation: .vertical, insertFirst: true)
        case .bottom:
            splitTarget = BrowserPaneSplitTarget(orientation: .vertical, insertFirst: false)
        }

        return .move(
            tabId: transfer.tabId,
            targetWorkspaceId: target.workspaceId,
            targetPane: target.paneId,
            splitTarget: splitTarget
        )
    }

    static func filePreviewDestination(
        target: BrowserPaneDropContext,
        zone: DropZone
    ) -> BonsplitController.ExternalTabDropRequest.Destination {
        PaneDropRouting.filePreviewDestination(targetPane: target.paneId, zone: zone)
    }
}
