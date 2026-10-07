public import CoreGraphics

/// DRAG-SHAPE-INVARIANT (spec decisions.md, Lawrence 2026-10-07): while a
/// dragged tab or workspace is over a surface that takes it in place (a tab
/// strip for a tab, a sidebar list for a workspace), it keeps its own shape
/// and the neighbors make room; only outside every in-place surface does it
/// become the preview card. This file is the one rule for tab drags and
/// workspace drags in every window.

/// The dragged item's shape now.
public nonisolated enum DragShape: Hashable, Sendable {
    /// Its own shape in `target`, at `slot`.
    case inPlace(DragShapeTarget, slot: CGRect)
    /// The floating preview card.
    case card

    public var isInPlace: Bool {
        if case .inPlace = self { return true }
        return false
    }
}

/// Decides in place vs card for one drag. Pure; the drag session feeds it.
///
/// Per pointer move: `stickyProbe` first (while the pointer is inside the
/// held surface's leave band, that surface is asked first, at the pointer
/// clamped into it), else the normal hit test; then `resolve` with what the
/// winning surface answered (nil when no in-place surface answered).
public nonisolated struct DragShapeMachine: Hashable, Sendable {
    public private(set) var held: DragShapeTarget?
    public private(set) var shape: DragShape = .card

    public init() {}

    public func stickyProbe(_ pointer: CGPoint) -> (target: DragShapeTarget, point: CGPoint)? {
        nil
    }

    @discardableResult
    public mutating func resolve(_ answer: DragShapeAnswer?) -> DragShape {
        shape
    }

    public mutating func reset() {}

    public static func itemRect(_ shape: DragShape, pointer: CGPoint, grabOffset: CGPoint, itemSize: CGSize) -> CGRect {
        TabDragGeometry.floatingRect(pointer: pointer, grabOffset: grabOffset, tabSize: itemSize)
    }
}
