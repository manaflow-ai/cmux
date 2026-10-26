public import CoreGraphics

/// The drag ghost at rest on the render server (`motion.renderServer`): the screen origin of its root
/// view and its layers in the root's coordinates (y up), the scale already applied about the grabbed
/// point (`TabDragGhostLayout.onScreen`), so no layer carries a transform.
public nonisolated struct TabDragGhostRest: Equatable, Sendable {
    /// The root view's bottom-left corner on screen.
    public var origin: CGPoint
    /// The glass card's mask.
    public var glass: CGRect
    public var glassOpacity: CGFloat
    /// The content preview inside the card.
    public var thumb: CGRect
    public var thumbOpacity: CGFloat
    /// The tab image.
    public var tab: CGRect
    public var tabOpacity: CGFloat
    public var tabShadow: CGFloat

    /// The rest of `layout` (a settled motion's), whole ghost at `opacity`, in a root of `rootSize`
    /// that keeps `pad` of shadow room above and left of the tab. `onGlass`: the tab stands on the
    /// glass at every cardness and casts no shadow; else it casts `shadowAlpha` as a tab.
    public init(layout: TabDragGhostLayout, opacity: CGFloat, rootSize: CGSize, pad: CGFloat, inset: CGFloat,
                onGlass: Bool, shadowAlpha: CGFloat) {
        let tab = layout.tab, card = layout.card, c = layout.cardness
        let origin = CGPoint(x: (tab.minX - pad).rounded(), y: (tab.maxY + pad - rootSize.height).rounded())
        let thumb = CGRect(x: card.minX + inset, y: card.minY + inset, width: max(0, card.width - inset * 2),
                           height: max(0, card.height - tab.height - inset * 3))
        func local(_ rect: CGRect) -> CGRect { layout.onScreen(rect).offsetBy(dx: -origin.x, dy: -origin.y) }
        self.origin = origin
        glass = local(card)
        glassOpacity = (onGlass ? 1 : c) * opacity
        self.thumb = local(thumb)
        thumbOpacity = c * opacity
        self.tab = local(tab)
        tabOpacity = opacity
        tabShadow = onGlass ? 0 : shadowAlpha * (1 - c)
    }

    /// The same ghost, wherever it is.
    public func sameInside(_ other: TabDragGhostRest) -> Bool {
        var moved = self
        moved.origin = other.origin
        return moved == other
    }

    /// What draws, in screen coordinates.
    public var shownOnScreen: CGRect {
        glass.union(tab).offsetBy(dx: origin.x, dy: origin.y)
    }
}
