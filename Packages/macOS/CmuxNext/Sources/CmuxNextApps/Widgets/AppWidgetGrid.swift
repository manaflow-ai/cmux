public import CoreGraphics

/// Where a place's tiles go: the same tile unit as the New Tab grid, sized to the sidebar's width.
/// Two columns; a small tile is one square unit, a medium one takes both columns and one unit's
/// height. Tiles flow in the person's order: a small tile takes the next free column, a medium one
/// starts a new row when the current row already holds a small one (Apple's widget stack keeps the
/// order too, so a lone small tile before a medium one leaves its row's second column empty).
public nonisolated struct AppWidgetGrid: Sendable, Hashable {
    /// The gap between tiles, both ways.
    public var gap: CGFloat
    /// The inset of the grid from the area's leading and trailing edges.
    public var inset: CGFloat

    public init(gap: CGFloat, inset: CGFloat) {
        self.gap = gap
        self.inset = inset
    }

    /// The side of one square tile at `width`.
    public func unit(width: CGFloat) -> CGFloat {
        max(0, floor((width - 2 * inset - gap) / 2))
    }

    /// Each tile's frame (flipped: y grows down) for `sizes` in order, and the grid's height.
    /// `large` (never placed in the sidebar) draws as medium.
    public func layout(_ sizes: [AppWidgetSize], width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let unit = unit(width: width)
        let full = unit * 2 + gap
        var frames: [CGRect] = []
        var row = 0
        var column = 0
        for size in sizes {
            if size != .small, column == 1 {
                row += 1
                column = 0
            }
            let y = CGFloat(row) * (unit + gap)
            if size == .small {
                frames.append(CGRect(x: inset + CGFloat(column) * (unit + gap), y: y, width: unit, height: unit))
                column += 1
                if column == 2 {
                    row += 1
                    column = 0
                }
            } else {
                frames.append(CGRect(x: inset, y: y, width: full, height: unit))
                row += 1
            }
        }
        let rows = row + (column > 0 ? 1 : 0)
        let height = rows == 0 ? 0 : CGFloat(rows) * unit + CGFloat(rows - 1) * gap
        return (frames, height)
    }

    /// The index a tile dragged to `point` lands at among `frames` (the tiles without it): before
    /// the first tile whose center comes after the point in reading order, else at the end.
    public func dropIndex(at point: CGPoint, in frames: [CGRect]) -> Int {
        for (index, frame) in frames.enumerated() {
            if point.y < frame.minY { return index }
            if point.y <= frame.maxY, point.x < frame.midX { return index }
        }
        return frames.count
    }
}
