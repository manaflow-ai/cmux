import CoreGraphics

// The content layouts of a browser page's status views and glass cards, over
// `ChromeColumnLayout` (ChromeFrameLayout.swift).

/// A full-page message (the load error page, the sad tab): a centered
/// column raised by `lift`, at most `maxWidth` wide and `margin` from the
/// sides; on a page too short for it, its top stays on the page.
nonisolated struct PageMessageLayout: Equatable, Sendable {
    var column: ChromeColumnLayout
    var maxWidth: CGFloat
    var margin: CGFloat
    var lift: CGFloat

    /// The width each item measures at in `bounds`.
    func itemWidth(in bounds: CGRect) -> CGFloat {
        max(min(maxWidth, bounds.width - margin * 2) - column.insets.horizontal, 0)
    }

    /// Each item's rect in `bounds` (items measured at `itemWidth(in:)`).
    func place(_ items: [CGSize], in bounds: CGRect) -> [CGRect] {
        let size = column.size(of: items)
        let width = min(size.width, itemWidth(in: bounds) + column.insets.horizontal)
        let height = size.height
        let centered = bounds.midY + lift - height / 2
        let y = max(min(centered, bounds.maxY - height), min(bounds.minY, bounds.maxY - height))
        let box = CGRect(x: (bounds.midX - width / 2).rounded(.down), y: y.rounded(.down), width: width, height: height)
        return column.place(items, in: box)
    }
}

/// A glass card over the page (the prompt bar, the "Page unresponsive"
/// card): a column whose width is its content's natural width, at least
/// `minWidth` (a preferred minimum: a narrower room wins) and at most
/// `maxWidth`, never wider than the room.
nonisolated struct OverlayCardLayout: Equatable, Sendable {
    var column: ChromeColumnLayout
    var minWidth: CGFloat
    var maxWidth: CGFloat

    /// The widest an item may measure in a room `room` wide.
    func maxItemWidth(room: CGFloat) -> CGFloat {
        max(min(maxWidth, room) - column.insets.horizontal, 0)
    }

    /// The card's width for items measured at `maxItemWidth(room:)`.
    func width(natural items: [CGSize], room: CGFloat) -> CGFloat {
        let natural = column.size(of: items).width
        return max(min(min(max(natural, minWidth), maxWidth), room), 0)
    }

    /// The card's size for items measured at its inner width.
    func size(width: CGFloat, items: [CGSize]) -> CGSize {
        CGSize(width: width, height: column.size(of: items).height)
    }
}
