public import CoreGraphics

/// Where a sidebar row's hover card sits, and which part of the screen keeps it
/// (`HoverCardPlacement.besideRow`). Pure: no window, no view.
///
/// Leo 2026-10-21: "WHY HAS IT NOT BEEN ALIGNED". The card sits beside the sidebar with its top
/// on the hovered row's top, as Chrome's and Arc's tab hover cards do, `rowGap` off the row,
/// and it follows the row from row to row. Near the screen's bottom edge the visible frame
/// clamps it up (it still covers the row's side); near its right edge it goes left of the row.
///
/// ```
///   +-----------+    +--------------------+
///   |    row    |gap |                    |   (the card's top on the row's top)
///   +-----------+    |        card        |
///                    +--------------------+
/// ```
///
/// The gap keeps the card only for a pointer heading into it (`HoverCardCoordinator`); one
/// moving down past the row lets it go (Leo 2026-10-20).
///
/// `RowAlignment.middle` keeps the earlier layout (#22473, Leo 2026-10-20 "trapped by the
/// preview"): the card's top on the row's middle, so right of the row's upper half is an empty
/// escape slot that dismisses the card. It flips above the row's middle near the screen's bottom.
/// Debug Settings turns it back on (`escapeSlotTunable`). Coordinates are screen points, y up.
public nonisolated struct HoverCardEscapeGeometry: Hashable, Sendable {
    /// What a point is, for a shown card.
    public enum Zone: Hashable, Sendable {
        /// On the row the card describes.
        case row
        /// On the card.
        case card
        /// In the empty slot beside the row: the card goes.
        case escape
        /// Between the row and the card: the card stays only for a pointer heading into it.
        case gap
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
    /// The strip between the row and the card, beside the card; empty when they touch.
    public private(set) var gapStrip: CGRect
    /// The card sits left of its row (no room on the right).
    public private(set) var isLeading: Bool

    /// Which edge of the card goes where on its row.
    public enum RowAlignment: Hashable, Sendable {
        /// The card's top on the row's top (Chrome, Arc). No escape slot.
        case top
        /// The card's top on the row's middle, below an escape slot beside the row's upper half.
        case middle
    }

    /// The room between a sidebar row (or header, or card) and the card beside it.
    public static let rowGap: CGFloat = 10

    /// Debug Settings: the escape-slot layout (`RowAlignment.middle`) instead of the top-aligned one.
    public static let escapeSlotTunable = Tunable<Bool>.toggle(
        "sidebar.hoverCardEscapeSlot", .sidebar, "Workspace card below the row's middle",
        help: "The workspace hover card starts at its row's middle, leaving an empty slot beside the row's upper half that dismisses it, instead of lining its top up with the row's top.",
        default: false, code: "HoverCardEscapeGeometry.escapeSlotTunable")

    /// The alignment the sidebar uses now: top, or middle while the Debug Settings switch is on.
    public static var currentAlignment: RowAlignment { escapeSlotTunable.value ? .middle : .top }

    /// The card for `anchor` at `size`, kept inside `visible` (the screen's visible frame,
    /// already inset by any margin) when given, its near edge `gap` off the row on device pixels
    /// of `scale`, lined up with the row by `alignment`.
    public init(anchor: CGRect, cardSize size: CGSize, visible: CGRect? = nil, scale: CGFloat = 2, gap: CGFloat = rowGap,
                alignment: RowAlignment = .top) {
        let scale = max(scale, 1)
        func up(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.up) / scale }
        func down(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.down) / scale }
        self.anchor = anchor
        let middle = down(anchor.midY)
        // Right of the row, its left edge `gap` past the row's trailing edge (rounded toward the row).
        var x = down(anchor.maxX + gap)
        var leading = false
        if let visible, x + size.width > visible.maxX, up(anchor.minX - gap) - size.width >= visible.minX {
            x = up(anchor.minX - gap) - size.width
            leading = true
        }
        var y: CGFloat
        var below = true
        switch alignment {
        case .top:
            // The card's top on the row's top, on a device pixel; the clamp below keeps it on screen.
            y = (anchor.maxY * scale).rounded() / scale - size.height
        case .middle:
            // Below the slot: the card's top on the row's middle; above it near the screen's bottom.
            y = middle - size.height
            if let visible, y < visible.minY, middle + size.height <= visible.maxY {
                y = middle
                below = false
            }
        }
        if let visible {
            x = min(max(x, visible.minX), visible.maxX - size.width)
            y = min(max(y, visible.minY), visible.maxY - size.height)
        }
        let card = CGRect(x: x, y: y, width: size.width, height: size.height)
        self.card = card
        isLeading = leading
        // The slot spans from the row to the card's far edge, beside the row's far half (the
        // row's upper half when the card is below).
        let slotX = leading ? card.minX : anchor.maxX
        let slotWidth = leading ? max(0, anchor.minX - slotX) : max(0, card.maxX - slotX)
        let slot = below
            ? CGRect(x: slotX, y: card.maxY, width: slotWidth, height: max(0, anchor.maxY - card.maxY))
            : CGRect(x: slotX, y: anchor.minY, width: slotWidth, height: max(0, card.minY - anchor.minY))
        escapeSlot = alignment == .middle && slot.width > 0 && slot.height > 0 ? slot : .zero
        let strip = leading
            ? CGRect(x: card.maxX, y: card.minY, width: max(0, anchor.minX - card.maxX), height: card.height)
            : CGRect(x: anchor.maxX, y: card.minY, width: max(0, card.minX - anchor.maxX), height: card.height)
        gapStrip = strip.width > 0 && strip.height > 0 ? strip : .zero
    }

    /// What `point` is: the card first, then the row, the slot and the gap.
    public func zone(at point: CGPoint) -> Zone {
        if card.contains(point) { return .card }
        if anchor.contains(point) { return .row }
        if escapeSlot.contains(point) { return .escape }
        if gapStrip.contains(point) { return .gap }
        return .outside
    }

    /// Whether the pointer at `point` keeps the card by where it is: on the row or on the card.
    /// In the gap only a pointer heading into the card keeps it (`HoverCardCoordinator`).
    public func keepsCard(at point: CGPoint) -> Bool {
        switch zone(at: point) {
        case .row, .card: true
        case .escape, .gap, .outside: false
        }
    }
}
