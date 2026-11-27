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
    /// (the fade width) between it and a scrolled edge. `fixedLeading` is the
    /// pinned band (`TabScrollMapping.band`): a pinned tab in it is always in
    /// view, and an unpinned tab shows from the band's trailing edge on.
    public static func offset(
        revealing slot: TabLayoutSlot,
        current: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat,
        margin: CGFloat,
        fixedLeading: CGFloat = 0
    ) -> CGFloat {
        if slot.isPinned, fixedLeading > 0 { return clamp(current, contentWidth: contentWidth, viewportWidth: viewportWidth) }
        var offset = current
        let leading = slot.x - (slot.x > fixedLeading ? margin : 0)
        let trailing = slot.maxX + (slot.maxX < contentWidth ? margin : 0)
        if trailing - offset > viewportWidth { offset = trailing - viewportWidth }
        if leading - fixedLeading < offset { offset = leading - fixedLeading }
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

/// Where the strip shows its tabs for a scroll offset (cx-kp9b4): the pinned
/// tabs and the gap after them are a band fixed at the leading edge (Safari,
/// Arc), and only the unpinned tabs scroll, under and after it. The scroll
/// range does not change: the unpinned tabs (content minus band) scroll in the
/// viewport minus band. Every strip x that depends on the scroll goes through
/// this mapping (frames, hit tests, drags, drop gaps, closing mode, reveal).
public struct TabScrollMapping: Equatable, Sendable {
    /// Width of the fixed band, pinned tabs plus gap; 0 when nothing is fixed.
    public var band: CGFloat
    /// The strip's scroll offset, which the unpinned tabs take.
    public var offset: CGFloat

    public init(band: CGFloat, offset: CGFloat) {
        self.band = band
        self.offset = offset
    }

    /// The band for `result`: the first unpinned slot's x after leading pinned
    /// tabs. Pinned tabs that leave the unpinned ones less than
    /// `minimumScrollable` of `viewportWidth` (or no unpinned tab at all) fix
    /// nothing: then the whole strip scrolls, pinned tabs too.
    public init(result: TabLayoutResult, viewportWidth: CGFloat, minimumScrollable: CGFloat, offset: CGFloat) {
        var fixed: CGFloat = 0
        if result.slots.first?.isPinned == true, let first = result.slots.first(where: { !$0.isPinned }) { fixed = first.x }
        self.init(band: fixed > 0 && fixed + minimumScrollable <= viewportWidth ? fixed : 0, offset: offset)
    }

    /// The offset a tab in that region takes: 0 for a fixed pinned tab.
    public func offset(isPinned: Bool) -> CGFloat {
        isPinned && band > 0 ? 0 : offset
    }

    /// A content x (a layout slot's or a spring's) in the strip's clip.
    public func viewX(_ contentX: CGFloat, isPinned: Bool) -> CGFloat {
        contentX - offset(isPinned: isPinned)
    }

    /// A clip x as a content x in the pinned or the unpinned region.
    public func contentX(_ viewX: CGFloat, isPinned: Bool) -> CGFloat {
        viewX + offset(isPinned: isPinned)
    }

    /// Whether an unpinned tab can show (or be hit) at clip x `viewX`: not under the band.
    public func showsUnpinned(at viewX: CGFloat) -> Bool {
        viewX >= band
    }
}
