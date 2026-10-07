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

    /// The held surface and the point to ask it at, while `pointer` is
    /// inside its leave band (the point is clamped into the surface, so its
    /// own hit test answers). Nil when nothing is held or the pointer left
    /// the band: the normal hit test decides.
    public func stickyProbe(_ pointer: CGPoint) -> (target: DragShapeTarget, point: CGPoint)? {
        guard let held else { return nil }
        let band = held.bounds.insetBy(dx: -held.leaveMargin, dy: -held.leaveMargin)
        guard band.contains(pointer) else { return nil }
        let inside = held.bounds.insetBy(dx: min(0.5, held.bounds.width / 2), dy: min(0.5, held.bounds.height / 2))
        let point = CGPoint(x: min(max(pointer.x, inside.minX), inside.maxX), y: min(max(pointer.y, inside.minY), inside.maxY))
        return (held, point)
    }

    /// The shape for what the winning surface answered: in place when an
    /// in-place surface takes the item, else the card.
    @discardableResult
    public mutating func resolve(_ answer: DragShapeAnswer?) -> DragShape {
        if let answer, answer.accepts {
            held = answer.target
            shape = .inPlace(answer.target, slot: answer.slot)
        } else {
            held = nil
            shape = .card
        }
        return shape
    }

    /// The drag ended or was cancelled.
    public mutating func reset() {
        held = nil
        shape = .card
    }

    /// The item's screen rect for `shape`: under the pointer as a card; in
    /// place it takes the slot's size and keeps the grabbed fraction under
    /// the pointer along the surface's axis, locked to the slot across it.
    public static func itemRect(_ shape: DragShape, pointer: CGPoint, grabOffset: CGPoint, itemSize: CGSize) -> CGRect {
        guard case .inPlace(let target, let slot) = shape else {
            return TabDragGeometry.floatingRect(pointer: pointer, grabOffset: grabOffset, tabSize: itemSize)
        }
        switch target.axis {
        case .horizontal:
            return TabDragGeometry.inlineRect(pointer: pointer, grabOffset: grabOffset, tabSize: itemSize, slot: slot)
        case .vertical:
            let fraction = itemSize.height > 0 ? min(max(grabOffset.y / itemSize.height, 0), 1) : 0.5
            return CGRect(x: slot.minX, y: pointer.y - fraction * itemSize.height, width: slot.width, height: itemSize.height)
        }
    }
}
