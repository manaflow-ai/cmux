public import CoreGraphics

/// The move and resize handles of a canvas: a band `thickness` canvas points
/// wide around each pane, outside its frame. The band above a pane moves it;
/// the sides, the bottom and the corners resize it. A pane's own frame and
/// any pane in front of the band take the point first.
public nonisolated struct CanvasHandles: Hashable, Sendable {
    /// The canvas the handles belong to.
    public var canvas: CanvasScreen
    /// Band width in canvas points (a fixed screen width over the zoom).
    public var thickness: CGFloat

    /// The handles of `canvas`, `thickness` canvas points wide.
    public init(canvas: CanvasScreen, thickness: CGFloat) {
        self.canvas = canvas
        self.thickness = thickness
    }

    /// The handle under `point` (canvas points): the pane and the edges it
    /// moves (empty: the move band). Nil over a pane or the empty canvas.
    public func hit(_ point: CGPoint) -> (pane: PaneID, edges: CanvasResizeEdges)? {
        for pane in canvas.order.reversed() {
            guard let frame = canvas.frames[pane] else { continue }
            if frame.contains(point) { return nil }
            guard frame.insetBy(dx: -thickness, dy: -thickness).contains(point) else { continue }
            var edges: CanvasResizeEdges = []
            if point.x < frame.minX { edges.insert(.left) }
            if point.x >= frame.maxX { edges.insert(.right) }
            if point.y >= frame.maxY { edges.insert(.bottom) }
            // Above the pane: its move band, except at the corners, which resize.
            if point.y < frame.minY, !edges.isEmpty { edges.insert(.top) }
            return (pane, edges)
        }
        return nil
    }
}
