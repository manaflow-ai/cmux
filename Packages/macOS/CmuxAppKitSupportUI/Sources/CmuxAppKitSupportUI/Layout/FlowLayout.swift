public import SwiftUI

/// A SwiftUI `Layout` that flows its subviews left to right, wrapping onto a new
/// row whenever the next subview would overflow the proposed width.
///
/// `FlowLayout` is a self-contained geometry primitive with no domain coupling:
/// it measures each subview at its ideal (`.unspecified`) size, packs subviews
/// into rows separated by `spacing`, and starts a new row when the running x
/// offset plus the next subview's width exceeds the available width. The same
/// row/overflow arithmetic drives both `sizeThatFits(proposal:subviews:cache:)`
/// and `placeSubviews(in:proposal:subviews:cache:)`, so the reported size and
/// the placed frames always agree.
public struct FlowLayout: Layout {
    /// Horizontal gap inserted between adjacent subviews, and vertical gap
    /// inserted between wrapped rows.
    public var spacing: CGFloat

    /// Creates a flow layout.
    /// - Parameter spacing: The gap between adjacent subviews and between rows.
    public init(spacing: CGFloat = 4) {
        self.spacing = spacing
    }

    /// Reports the total size needed to lay the subviews out as wrapped rows
    /// within the proposed width.
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                totalHeight += currentRowHeight + spacing
                totalWidth = max(totalWidth, currentX - spacing)
                currentX = 0
                currentRowHeight = 0
            }
            currentX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
        totalHeight += currentRowHeight
        totalWidth = max(totalWidth, currentX - spacing)
        return CGSize(width: totalWidth, height: totalHeight)
    }

    /// Places each subview at its computed position within `bounds`, wrapping to
    /// a new row when a subview would overflow the right edge.
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
