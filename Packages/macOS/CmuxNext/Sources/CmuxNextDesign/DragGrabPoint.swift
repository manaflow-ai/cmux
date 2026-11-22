public import CoreGraphics

/// The point a drag holds its item by, measured once at mouse-down so a
/// hand-off later in the drag (tab strip -> App drag session, sidebar row ->
/// window drag) keeps the pointer on the same spot of the item.
public nonisolated enum DragGrabPoint {
    /// Offset of `point` from `frame`'s bottom-left corner, y up (screen
    /// orientation), clamped to the frame. `point` and `frame` are in one
    /// view's coordinates; `flipped` is that view's `isFlipped`.
    public static func screenOffset(of point: CGPoint, in frame: CGRect, flipped: Bool) -> CGPoint {
        let x = min(max(point.x - frame.minX, 0), frame.width)
        let fromTop = flipped ? point.y - frame.minY : frame.maxY - point.y
        return CGPoint(x: x, y: frame.height - min(max(fromTop, 0), frame.height))
    }
}
