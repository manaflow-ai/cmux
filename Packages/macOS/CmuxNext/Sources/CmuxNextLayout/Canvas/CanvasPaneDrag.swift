public import CoreGraphics

/// One move or resize drag of a canvas pane: the frame it started from, the
/// edges it moves (none moves the pane) and the smallest size it may reach.
/// ``frame(translation:)`` is the pane's frame for a pointer that moved by a
/// translation in canvas points.
public nonisolated struct CanvasPaneDrag: Hashable, Sendable {
    /// The pane being dragged.
    public var pane: PaneID
    /// The pane's frame when the drag began.
    public var start: CGRect
    /// The edges that follow the pointer; empty moves the whole pane.
    public var edges: CanvasResizeEdges
    /// A resize stops at this size; the opposite edge never moves.
    public var minimumSize: CGSize

    /// A drag of `pane` from `start` moving `edges`.
    public init(pane: PaneID, start: CGRect, edges: CanvasResizeEdges, minimumSize: CGSize) {
        self.pane = pane
        self.start = start
        self.edges = edges
        self.minimumSize = minimumSize
    }

    /// The frame after the pointer moved `translation` canvas points.
    public func frame(translation: CGSize) -> CGRect {
        guard !edges.isEmpty else { return start.offsetBy(dx: translation.width, dy: translation.height) }
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if edges.contains(.left) { minX = min(start.minX + translation.width, maxX - minimumSize.width) }
        if edges.contains(.right) { maxX = max(start.maxX + translation.width, minX + minimumSize.width) }
        if edges.contains(.top) { minY = min(start.minY + translation.height, maxY - minimumSize.height) }
        if edges.contains(.bottom) { maxY = max(start.maxY + translation.height, minY + minimumSize.height) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
