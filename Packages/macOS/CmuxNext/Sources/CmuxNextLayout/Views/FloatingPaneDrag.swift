import CoreGraphics

/// A pointer's move or resize of a floating pane: local until its release (one `setFloatingFrame` intent). The
/// frame follows the pointer in the same frame as the input, with no spring (direct manipulation).
struct FloatingPaneDrag {
    var pane: PaneID
    var zone: FloatingPaneCardView.Zone
    /// Where the press was, and the card then (the screen view's coordinates).
    var startPoint: CGPoint
    var startCard: CGRect
    /// The frame the drag shows now, as fractions of the pane area.
    var frame: CGRect

    /// The frame with the pointer at `point`, in a pane area of `size`: the card moved, or the edges of the zone
    /// moved while the opposite edges stay, inside the pane area and not smaller than the smallest floating pane.
    func frame(at point: CGPoint, in size: CGSize) -> CGRect {
        let dx = point.x - startPoint.x, dy = point.y - startPoint.y
        let minWidth = LayoutFloatingPane.minimumExtent * size.width, minHeight = LayoutFloatingPane.minimumExtent * size.height
        var card = startCard
        if zone == .move {
            card.origin.x = min(max(startCard.minX + dx, 0), max(0, size.width - startCard.width))
            card.origin.y = min(max(startCard.minY + dy, 0), max(0, size.height - startCard.height))
        }
        if zone.movesLeft {
            let minX = min(max(startCard.minX + dx, 0), startCard.maxX - minWidth)
            card.origin.x = minX
            card.size.width = startCard.maxX - minX
        }
        if zone.movesRight {
            card.size.width = min(max(startCard.width + dx, minWidth), size.width - startCard.minX)
        }
        if zone.movesTop {
            let minY = min(max(startCard.minY + dy, 0), startCard.maxY - minHeight)
            card.origin.y = minY
            card.size.height = startCard.maxY - minY
        }
        if zone.movesBottom {
            card.size.height = min(max(startCard.height + dy, minHeight), size.height - startCard.minY)
        }
        return LayoutFloatingPane.clamped(LayoutFloatingPane.fractions(of: card, in: size))
    }
}
