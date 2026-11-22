public import CoreGraphics

/// Drag reorder math.
public struct TabReorderMath {
    public init() {}
    /// Index at which a dragged tab lands among `otherWidths` (the tabs of its
    /// group in order, without the dragged tab). Picks the slot whose leading
    /// edge is nearest to the dragged tab's leading edge.
    public static func insertionIndex(draggedMinX: CGFloat, groupStart: CGFloat, otherWidths: [CGFloat]) -> Int {
        var best = 0
        var bestDistance = CGFloat.infinity
        var edge = groupStart
        for index in 0...otherWidths.count {
            let distance = abs(edge - draggedMinX)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
            if index < otherWidths.count { edge += otherWidths[index] }
        }
        return best
    }
}

/// Horizontal overflow scrolling math.
public struct TabScrollMath {
    public init() {}
    public static func maxOffset(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        max(0, contentWidth - viewportWidth)
    }

    public static func clamp(_ offset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        min(max(0, offset), maxOffset(contentWidth: contentWidth, viewportWidth: viewportWidth))
    }

    /// The smallest scroll change that shows `slot` fully, keeping `margin`
    /// (the fade width) between it and a scrolled edge.
    public static func offset(
        revealing slot: TabLayoutSlot,
        current: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat,
        margin: CGFloat
    ) -> CGFloat {
        var offset = current
        let leading = slot.x - (slot.x > 0 ? margin : 0)
        let trailing = slot.maxX + (slot.maxX < contentWidth ? margin : 0)
        if trailing - offset > viewportWidth { offset = trailing - viewportWidth }
        if leading < offset { offset = leading }
        return clamp(offset, contentWidth: contentWidth, viewportWidth: viewportWidth)
    }

    /// Which edges show a fade for a scroll offset: an edge with more than
    /// half a point of tabs hidden beyond it. The offset is clamped first,
    /// so a rubber band past either end never flashes a fade.
    public static func fadedEdges(offset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat) -> (leading: Bool, trailing: Bool) {
        let maximum = maxOffset(contentWidth: contentWidth, viewportWidth: viewportWidth)
        let clamped = clamp(offset, contentWidth: contentWidth, viewportWidth: viewportWidth)
        return (clamped > 0.5, clamped < maximum - 0.5)
    }
}
