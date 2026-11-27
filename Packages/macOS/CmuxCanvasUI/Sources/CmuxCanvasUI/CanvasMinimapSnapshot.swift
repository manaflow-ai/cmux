import CoreGraphics
import CmuxCanvas

/// Value snapshot used by the canvas minimap to draw and navigate without
/// reading live AppKit view state during rendering.
struct CanvasMinimapSnapshot: Equatable {
    let panes: [CanvasMinimapPaneSnapshot]
    let visibleRect: CGRect
    let focusedPaneID: CanvasPaneID?
    let navigationBounds: CGRect
    private let contentBounds: CGRect?

    init(
        panes: [CanvasMinimapPaneSnapshot],
        visibleRect: CGRect,
        focusedPaneID: CanvasPaneID?
    ) {
        self.panes = panes
        self.visibleRect = visibleRect
        self.focusedPaneID = focusedPaneID

        let content = panes.map(\.frame).reduce(nil) { partial, frame -> CGRect? in
            partial?.union(frame) ?? frame
        }
        self.contentBounds = content
        var bounds = (content ?? visibleRect).union(visibleRect)
        if bounds.width < 1 {
            bounds.origin.x -= 0.5
            bounds.size.width = 1
        }
        if bounds.height < 1 {
            bounds.origin.y -= 0.5
            bounds.size.height = 1
        }
        self.navigationBounds = bounds
    }

    var shouldShow: Bool {
        guard visibleRect.width > 1, visibleRect.height > 1 else { return false }
        guard !panes.isEmpty else { return false }
        guard let content = contentBounds else { return false }
        return panes.count > 1 || !visibleRect.insetBy(dx: -24, dy: -24).contains(content)
    }

    func projection(in drawingRect: CGRect) -> CanvasMinimapProjection {
        guard drawingRect.width > 0, drawingRect.height > 0 else {
            return CanvasMinimapProjection(scale: 1, origin: drawingRect.origin)
        }
        let scale = min(
            drawingRect.width / navigationBounds.width,
            drawingRect.height / navigationBounds.height
        )
        let usedSize = CGSize(
            width: navigationBounds.width * scale,
            height: navigationBounds.height * scale
        )
        return CanvasMinimapProjection(
            scale: scale,
            origin: CGPoint(
                x: drawingRect.minX + (drawingRect.width - usedSize.width) / 2,
                y: drawingRect.minY + (drawingRect.height - usedSize.height) / 2
            )
        )
    }

    func minimapRect(for canvasRect: CGRect, in drawingRect: CGRect) -> CGRect {
        let projection = projection(in: drawingRect)
        return CGRect(
            x: projection.origin.x + (canvasRect.minX - navigationBounds.minX) * projection.scale,
            y: projection.origin.y + (canvasRect.minY - navigationBounds.minY) * projection.scale,
            width: canvasRect.width * projection.scale,
            height: canvasRect.height * projection.scale
        )
    }

    func projectedNavigationBounds(in drawingRect: CGRect) -> CGRect {
        let projection = projection(in: drawingRect)
        return CGRect(
            x: projection.origin.x,
            y: projection.origin.y,
            width: navigationBounds.width * projection.scale,
            height: navigationBounds.height * projection.scale
        )
    }

    func canvasPoint(for minimapPoint: CGPoint, in drawingRect: CGRect) -> CGPoint {
        let projection = projection(in: drawingRect)
        return CGPoint(
            x: navigationBounds.minX + (minimapPoint.x - projection.origin.x) / projection.scale,
            y: navigationBounds.minY + (minimapPoint.y - projection.origin.y) / projection.scale
        )
    }
}
