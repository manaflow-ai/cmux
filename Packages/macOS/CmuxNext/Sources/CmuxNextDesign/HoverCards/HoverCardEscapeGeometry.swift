public import CoreGraphics

/// Where a sidebar row's hover card sits, and which part of the screen keeps it
/// (`HoverCardPlacement.besideRow`). Pure: no window, no view.
///
/// Leo 2026-10-20: dismissing the workspace card took too much travel ("trapped by the
/// preview"). Top-aligned against its row, the card filled everything right of the row, so
/// the only way out was across its whole width. Now the card's near edge starts at the row's
/// middle: right of the row's other half is an empty escape slot the card never covers, and
/// the pointer there dismisses the card at once. The half the card faces still touches it, so
/// a pointer moving straight across keeps the card.
///
/// ```
///   +-----------+ . . . . . . . . . .
///   |    row    |   escape slot      :   (the pointer here dismisses the card)
///   |           +--------------------+
///   +-----------|                    |   (straight right from here: the card)
///               |        card        |
///               +--------------------+
/// ```
///
/// The card goes right of the row and below the slot when it fits on screen; it flips above
/// (slot below) near the screen's bottom edge and left of the row near its right edge, so the
/// slot survives the screen clamp. Coordinates are screen points, y up.
public nonisolated struct HoverCardEscapeGeometry: Hashable, Sendable {
    /// What a point is, for a shown card.
    public enum Zone: Hashable, Sendable {
        /// On the row the card describes.
        case row
        /// On the card.
        case card
        /// In the empty slot beside the row: the card goes.
        case escape
        /// Anywhere else.
        case outside
    }

    /// The row's frame.
    public private(set) var anchor: CGRect
    /// The card's frame at rest.
    public private(set) var card: CGRect
    /// The empty slot beside the row that the card never covers; empty when the screen left
    /// no room for one.
    public private(set) var escapeSlot: CGRect
    /// The card sits left of its row (no room on the right).
    public private(set) var isLeading: Bool

    /// The card for `anchor` at `size`, kept inside `visible` (the screen's visible frame,
    /// already inset by any margin) when given, its touching edges on device pixels of `scale`.
    public init(anchor: CGRect, cardSize size: CGSize, visible: CGRect? = nil, scale: CGFloat = 2) {
        let scale = max(scale, 1)
        func up(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.up) / scale }
        func down(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.down) / scale }
        self.anchor = anchor
        let middle = down(anchor.midY)
        // Right of the row, its left edge on the row's trailing edge (rounded into the row).
        var x = down(anchor.maxX)
        var leading = false
        if let visible, x + size.width > visible.maxX, up(anchor.minX) - size.width >= visible.minX {
            x = up(anchor.minX) - size.width
            leading = true
        }
        // Below the slot: the card's top on the row's middle; above it near the screen's bottom.
        var y = middle - size.height
        var below = true
        if let visible, y < visible.minY, middle + size.height <= visible.maxY {
            y = middle
            below = false
        }
        if let visible {
            x = min(max(x, visible.minX), visible.maxX - size.width)
            y = min(max(y, visible.minY), visible.maxY - size.height)
        }
        let card = CGRect(x: x, y: y, width: size.width, height: size.height)
        self.card = card
        isLeading = leading
        // The slot spans the card's width beside the row, between the card's near edge and the
        // row's far one (the row's upper half when the card is below).
        let slotX = leading ? card.maxX - size.width : anchor.maxX
        let slotWidth = leading ? max(0, anchor.minX - slotX) : size.width
        let slot = below
            ? CGRect(x: slotX, y: card.maxY, width: slotWidth, height: max(0, anchor.maxY - card.maxY))
            : CGRect(x: slotX, y: anchor.minY, width: slotWidth, height: max(0, card.minY - anchor.minY))
        escapeSlot = slot.width > 0 && slot.height > 0 ? slot : .zero
    }

    /// What `point` is: the card first, then the row, then the slot.
    public func zone(at point: CGPoint) -> Zone {
        if card.contains(point) { return .card }
        if anchor.contains(point) { return .row }
        if escapeSlot.contains(point) { return .escape }
        return .outside
    }

    /// Whether the pointer at `point` keeps the card: on the row or on the card.
    public func keepsCard(at point: CGPoint) -> Bool {
        switch zone(at: point) {
        case .row, .card: true
        case .escape, .outside: false
        }
    }
}
