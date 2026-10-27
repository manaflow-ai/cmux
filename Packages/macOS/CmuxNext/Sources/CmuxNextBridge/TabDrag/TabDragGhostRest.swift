public import Foundation

/// The drag ghost at rest on the render server (`motion.renderServer`): the screen origin of its root
/// view and its layers in the root's coordinates (y up), the scale already applied about the grabbed
/// point (`TabDragGhostLayout.onScreen`), so no layer carries a transform.
public nonisolated struct TabDragGhostRest: Equatable, Sendable {
    /// The root view's bottom-left corner on screen.
    public var origin: CGPoint
    /// The glass card (its clip, in the root).
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

/// Where the drag ghost may still draw while its render-server springs run: the offsets from its rest
/// origin its root still flies from (each jump adds its start offset) and what showed in the root when
/// they started. The newest spring call's landing clears it. A host holds the ghost only with this
/// room, so a host change never clips a flight.
public nonisolated struct TabDragGhostFlight: Equatable, Sendable {
    /// The root's offsets from its rest origin, as a rect around zero.
    public private(set) var offsets = CGRect.zero
    /// What showed in the root when the springs started (root coordinates).
    public private(set) var drawn = CGRect.null

    public init() {}

    /// A spring starts from `drawn` (root coordinates), the root `shift` away from its rest.
    public mutating func add(shift: CGPoint, drawn: CGRect) {
        self.drawn = self.drawn.union(drawn)
        offsets = CGRect(x: offsets.minX + min(0, shift.x), y: offsets.minY + min(0, shift.y),
                         width: offsets.width + abs(shift.x), height: offsets.height + abs(shift.y))
    }

    /// `rect` (screen) at every offset the root still flies from.
    public func widened(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + offsets.minX, y: rect.minY + offsets.minY,
               width: rect.width + offsets.width, height: rect.height + offsets.height)
    }

    /// Where the ghost may draw on screen at `rest`: what shows there and what showed when the
    /// springs started, at every offset the root still flies from.
    public func reach(of rest: TabDragGhostRest) -> CGRect {
        widened(rest.glass.union(rest.tab).union(drawn).offsetBy(dx: rest.origin.x, dy: rest.origin.y))
    }
}
