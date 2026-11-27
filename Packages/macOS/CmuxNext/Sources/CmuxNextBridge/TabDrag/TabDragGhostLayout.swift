public import CoreGraphics

/// Where the drag ghost draws for one motion frame, in screen space
/// (bottom-left origin): the tab image, the glass card that unfolds around
/// it, and the scale the whole ghost takes about `pivot`.
public nonisolated struct TabDragGhostLayout: Equatable, Sendable {
    /// The tab image before the scale.
    public var tab: CGRect
    /// The glass card before the scale: the tab itself at cardness 0, the
    /// full preview card (the tab at its top-left, content below) at 1.
    public var card: CGRect
    public var cardness: CGFloat
    public var scale: CGFloat
    /// The fixed point of the scale: the point the user grabbed, so a
    /// shrink over a drop target or the landing never slides the tab out
    /// from under the pointer (dogfood nxdog13).
    public var pivot: CGPoint

    /// `grabOffset` is the pointer's offset in the tab (y up) when the tab
    /// is `tabSize`; `cardSize` and `inset` are the full card's.
    public init(motion: TabDragGhostMotion, cardSize: CGSize, inset: CGFloat, grabOffset: CGPoint, tabSize: CGSize) {
        let tab = motion.presentedRect
        let c = motion.presentedCardness
        let full = CGRect(x: tab.minX - inset, y: tab.maxY + inset - cardSize.height, width: cardSize.width, height: cardSize.height)
        self.tab = tab
        card = Self.lerp(tab, full, c)
        cardness = c
        scale = motion.presentedScale
        pivot = TabDragGhostLayout.grabPoint(in: tab, grabOffset: grabOffset, tabSize: tabSize)
    }

    /// The grabbed point on a tab image drawn at `tab`: the same fraction
    /// of it as `grabOffset` is of `tabSize` (an inline slot can be wider).
    public static func grabPoint(in tab: CGRect, grabOffset: CGPoint, tabSize: CGSize) -> CGPoint {
        let fx = tabSize.width > 0 ? min(max(grabOffset.x / tabSize.width, 0), 1) : 0.5
        let fy = tabSize.height > 0 ? min(max(grabOffset.y / tabSize.height, 0), 1) : 0.5
        return CGPoint(x: tab.minX + fx * tab.width, y: tab.minY + fy * tab.height)
    }

    /// `point` after the scale.
    public func onScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: pivot.x + (point.x - pivot.x) * scale, y: pivot.y + (point.y - pivot.y) * scale)
    }

    /// `rect` after the scale.
    public func onScreen(_ rect: CGRect) -> CGRect {
        let origin = onScreen(rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * scale, height: rect.height * scale)
    }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
}
