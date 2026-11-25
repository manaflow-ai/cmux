import AppKit

/// The mask on the clip of a pane under a zoom's or an unzoom's moving pane: four opaque parts around a hole (above,
/// below, left, right) that is that pane's rect, so the pane under it shows only outside it.
///
/// A pane whose ground is clear (a docked Home in a glass or art window) hides nothing under it: without this mask a
/// covered or returning pane showed through it for the whole move (``PaneCommitMotion``). The hole goes with the
/// moving pane on the same additive springs (``moveHole(from:_:)``). Each part's frame is linear in the hole's edges
/// over an extent that holds every hole of the move, so a part that moves from one hole to the other is the part
/// of the hole between them at each point of the spring: a hole cut to the mask's bounds would not be.
nonisolated final class PaneHoleMaskLayer: CALayer {
    /// The extent that the parts fill: the mask's bounds and each hole of the move.
    private var extent: CGRect = .zero

    override init() {
        super.init()
        for _ in 0..<4 {
            let part = CALayer()
            part.backgroundColor = NSColor.black.cgColor // a mask reads alpha only
            addSublayer(part)
        }
    }

    override init(layer: Any) {
        super.init(layer: layer)
        extent = (layer as? PaneHoleMaskLayer)?.extent ?? .zero
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    private var parts: [CALayer] { sublayers ?? [] }

    /// Puts the mask over `bounds` (the masked layer's coordinates) with its hole at `hole`, from a move that starts
    /// with the hole at `old` (both in the mask's coordinates). The caller disables implicit actions.
    func place(_ bounds: CGRect, hole: CGRect, from old: CGRect) {
        frame = bounds
        extent = CGRect(origin: .zero, size: bounds.size).union(hole).union(old).insetBy(dx: -1, dy: -1)
        for (part, rect) in zip(parts, Self.rects(around: hole, in: extent)) { part.frame = rect }
    }

    /// The hole goes from `old` (the mask's coordinates) to where ``place(_:hole:from:)`` put it. `move` gets each
    /// part with how far its origin is from its place at the start, and how much larger it is then; it puts that
    /// move on the part's layer.
    func moveHole(from old: CGRect, _ move: (CALayer, CGPoint, CGSize) -> Void) {
        for (part, from) in zip(parts, Self.rects(around: old, in: extent)) {
            let now = part.frame
            let origin = CGPoint(x: from.minX - now.minX, y: from.minY - now.minY)
            let size = CGSize(width: from.width - now.width, height: from.height - now.height)
            if origin != .zero || size != .zero { move(part, origin, size) }
        }
    }

    /// The four parts of `extent` around `hole` (above, below, left, right); `hole` is inside `extent`.
    static func rects(around hole: CGRect, in extent: CGRect) -> [CGRect] {
        [CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: hole.minY - extent.minY),
         CGRect(x: extent.minX, y: hole.maxY, width: extent.width, height: extent.maxY - hole.maxY),
         CGRect(x: extent.minX, y: hole.minY, width: hole.minX - extent.minX, height: hole.height),
         CGRect(x: hole.maxX, y: hole.minY, width: extent.maxX - hole.maxX, height: hole.height)]
    }
}
