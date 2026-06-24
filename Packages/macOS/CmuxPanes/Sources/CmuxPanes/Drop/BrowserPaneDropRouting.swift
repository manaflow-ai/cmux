public import AppKit
public import Bonsplit

/// Routes a browser-pane drag to a drop zone, overlay frame, and resulting drop
/// action.
///
/// This is a stateless value: construct one and call its instance methods. The
/// geometry mirrors the terminal-pane drop routing (edge-band zone detection and
/// compact overlay frames) so browser panes and terminal panes feel identical
/// under a drag.
public struct BrowserPaneDropRouting: Sendable {
    /// Creates a browser-pane drop router.
    public init() {}

    /// Expands a pane's visible size to include the top chrome band, matching
    /// the coordinate space the drag locations arrive in.
    private func fullPaneSize(for size: CGSize, topChromeHeight: CGFloat) -> CGSize {
        CGSize(width: size.width, height: size.height + max(0, topChromeHeight))
    }

    /// Maps a drag location within a pane to its drop zone using 25%-edge bands
    /// (with an 80pt floor).
    public func zone(for location: CGPoint, in size: CGSize, topChromeHeight: CGFloat = 0) -> DropZone {
        let fullPaneSize = fullPaneSize(for: size, topChromeHeight: topChromeHeight)
        let edgeRatio: CGFloat = 0.25
        let horizontalEdge = max(80, fullPaneSize.width * edgeRatio)
        let verticalEdge = max(80, fullPaneSize.height * edgeRatio)

        if location.x < horizontalEdge {
            return .left
        } else if location.x > fullPaneSize.width - horizontalEdge {
            return .right
        } else if location.y > fullPaneSize.height - verticalEdge {
            return .top
        } else if location.y < verticalEdge {
            return .bottom
        } else {
            return .center
        }
    }

    /// The highlight overlay frame for a drop zone within a pane's size,
    /// accounting for the top chrome band.
    public func overlayFrame(for zone: DropZone, in size: CGSize, topChromeHeight: CGFloat = 0) -> CGRect {
        compactOverlayFrame(
            for: zone,
            in: CGRect(origin: .zero, size: fullPaneSize(for: size, topChromeHeight: topChromeHeight))
        )
    }

    /// The compact highlight overlay frame for a drop zone within bounds.
    private func compactOverlayFrame(for zone: DropZone, in bounds: CGRect) -> CGRect {
        let padding: CGFloat = 4
        let midX = bounds.midX
        let midY = bounds.midY

        switch zone {
        case .center:
            return bounds.insetBy(dx: padding, dy: padding)
        case .left:
            return CGRect(x: bounds.minX + padding, y: bounds.minY + padding, width: max(0, midX - bounds.minX - padding), height: max(0, bounds.height - padding * 2))
        case .right:
            return CGRect(x: midX, y: bounds.minY + padding, width: max(0, bounds.maxX - midX - padding), height: max(0, bounds.height - padding * 2))
        case .top:
            return CGRect(x: bounds.minX + padding, y: midY, width: max(0, bounds.width - padding * 2), height: max(0, bounds.maxY - midY - padding))
        case .bottom:
            return CGRect(x: bounds.minX + padding, y: bounds.minY + padding, width: max(0, bounds.width - padding * 2), height: max(0, midY - bounds.minY - padding))
        }
    }

    /// The drop action for a tab transfer landing in a zone of the target pane.
    /// Dropping a pane on its own center is a no-op; edge zones produce a split.
    public func action(
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

    /// The bonsplit external-tab drop destination for a file-preview drag
    /// landing in a zone of the target pane.
    public func filePreviewDestination(
        target: BrowserPaneDropContext,
        zone: DropZone
    ) -> BonsplitController.ExternalTabDropRequest.Destination {
        switch zone {
        case .center:
            return .insert(targetPane: target.paneId, targetIndex: nil)
        case .left:
            return .split(targetPane: target.paneId, orientation: .horizontal, insertFirst: true)
        case .right:
            return .split(targetPane: target.paneId, orientation: .horizontal, insertFirst: false)
        case .top:
            return .split(targetPane: target.paneId, orientation: .vertical, insertFirst: true)
        case .bottom:
            return .split(targetPane: target.paneId, orientation: .vertical, insertFirst: false)
        }
    }
}
