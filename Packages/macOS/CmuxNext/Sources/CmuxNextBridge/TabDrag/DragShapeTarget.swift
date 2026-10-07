public import CoreGraphics

// Inputs of `DragShapeMachine` (DRAG-SHAPE-INVARIANT).

/// The direction items flow in an in-place surface.
public nonisolated enum DragShapeAxis: Hashable, Sendable {
    /// A tab strip: the item follows the pointer sideways, its row is the slot's.
    case horizontal
    /// A sidebar list: the item follows the pointer up and down, its column is the slot's.
    case vertical
}

/// A surface that can take the dragged item in place.
public nonisolated struct DragShapeTarget: Hashable, Sendable {
    /// Identity of the surface (a strip id, a window's sidebar).
    public var key: String
    /// The surface on screen (bottom-left origin).
    public var bounds: CGRect
    public var axis: DragShapeAxis
    /// How far past `bounds` the pointer may go before the surface lets the
    /// item go: the surface's own hand-off distance (strip tear-off, sidebar
    /// side slack), so the boundary is the same before and after a hand-off.
    public var leaveMargin: CGFloat

    public init(key: String, bounds: CGRect, axis: DragShapeAxis, leaveMargin: CGFloat) {
        self.key = key
        self.bounds = bounds
        self.axis = axis
        self.leaveMargin = leaveMargin
    }
}

/// What the surface under the pointer answered for an in-place drop.
public nonisolated struct DragShapeAnswer: Hashable, Sendable {
    public var target: DragShapeTarget
    /// The slot the item takes (screen).
    public var slot: CGRect
    /// The surface takes the item here (a move or its own place). False for
    /// a refusal: a refused place is not in place, the item is a card.
    public var accepts: Bool

    public init(target: DragShapeTarget, slot: CGRect, accepts: Bool) {
        self.target = target
        self.slot = slot
        self.accepts = accepts
    }
}
