public import CoreGraphics

/// Screen geometry for the drag ghost and tear-off windows (screen space,
/// bottom-left origin).
public nonisolated enum TabDragGeometry {
    /// The tab image rect under the pointer while floating.
    public static func floatingRect(pointer: CGPoint, grabOffset: CGPoint, tabSize: CGSize) -> CGRect {
        CGRect(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y, width: tabSize.width, height: tabSize.height)
    }

    /// The tab image rect over a strip: it takes the slot's size and height
    /// and keeps following the pointer horizontally (the grab point stays at
    /// the same fraction of the tab), clamped to `strip`'s horizontal span
    /// when known. Neighbors slide around the slot underneath.
    public static func inlineRect(pointer: CGPoint, grabOffset: CGPoint, tabSize: CGSize, slot: CGRect,
                                  strip: ClosedRange<CGFloat>? = nil) -> CGRect {
        let fraction = tabSize.width > 0 ? min(max(grabOffset.x / tabSize.width, 0), 1) : 0.5
        var x = pointer.x - fraction * slot.width
        if let strip {
            x = min(max(x, strip.lowerBound), max(strip.lowerBound, strip.upperBound - slot.width))
        }
        return CGRect(x: x, y: slot.minY, width: slot.width, height: slot.height)
    }

    /// Frame for a torn-off window so its tab strip lands under the pointer:
    /// `tabOffset` is the dragged tab's top-left relative to its source
    /// window's top-left (x right, y down). Kept inside `visible`.
    public static func tearOffFrame(pointer: CGPoint, grabOffset: CGPoint, tabSize: CGSize, tabOffset: CGPoint,
                                    windowSize: CGSize, visible: CGRect) -> CGRect {
        let tabTopLeft = CGPoint(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y + tabSize.height)
        var frame = CGRect(x: tabTopLeft.x - tabOffset.x, y: tabTopLeft.y + tabOffset.y - windowSize.height,
                           width: min(windowSize.width, visible.width), height: min(windowSize.height, visible.height))
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }

    /// Preview card size for a content of `aspect` (height / width).
    public static func cardSize(tabSize: CGSize, aspect: CGFloat?, width: CGFloat = 264, inset: CGFloat = 6) -> CGSize {
        let cardWidth = max(width, tabSize.width + inset * 2)
        let ratio = min(max(aspect ?? 0.62, 0.45), 0.8)
        let thumbHeight = ((cardWidth - inset * 2) * ratio).rounded()
        return CGSize(width: cardWidth, height: tabSize.height + inset * 3 + thumbHeight)
    }
}
