public import AppKit

/// The update surfaces the What's New design draws in React (cx-urd.61.2): the staged
/// update's highlights in the card's hover popover, the "cmux Updated!" card after an update,
/// and that card's changes in the same kind of popover beside the sidebar
/// (``UpdatedCardPreviewMode/beside``).
public enum SidebarUpdateSurfaceKind: String, Sendable {
    case ready, updated
    case updatedNotes = "updated-notes"

    /// The surface shows the last update (the Updated card and its popover), not a staged one.
    public var showsLastUpdate: Bool { self != .ready }
}

/// One React surface the App mounts in a sidebar host (a page view). The
/// page reports its content height; the host sizes itself to it.
@MainActor
public protocol SidebarSurfaceIsland: AnyObject {
    var view: NSView { get }
    /// The content's height in points; 0 until the page has drawn.
    var contentHeight: CGFloat { get }
    /// The content's own width in points (the popover is as wide as its lines); 0 when the page
    /// fills the width it is given.
    var contentWidth: CGFloat { get }
    /// The content height changed.
    var onHeightChange: (() -> Void)? { get set }
    /// The page ran one of its actions (the popover then closes).
    var onAction: (() -> Void)? { get set }
    /// The page's x: the host sends its card's dismiss intent (one path for every card's x).
    var onDismiss: (() -> Void)? { get set }
    /// The sidebar went away: the page cancels its subscriptions.
    func close()
    /// The room, in points, the Updated card's open hover preview needs above its slot's bottom
    /// (the card and the preview's rows); 0 while the preview is closed.
    var overlayHeight: CGFloat { get }
    /// The height, in points, the Updated card's hover preview has once open; 0 from the moment it
    /// starts to close. The host's glass behind the page runs the page's motion to it.
    var previewHeight: CGFloat { get }
    /// Points per CSS px of the page (its interface scale); 1 for a surface that is not zoomed.
    var zoom: CGFloat { get }
    /// Tells the page whether the pointer is on its view (the host's tracking area): WebKit sends a
    /// page no pointer moves while another of the app's windows, a Chromium page's, has the key.
    func setPointerInside(_ inside: Bool)
    /// The person drags the Updated card (its page runs the drag): where it is held from its rest,
    /// and where it settles once let go.
    var onDrag: ((SidebarCardDrag) -> Void)? { get set }
    /// Tells the page where the card rests and how far it may be dragged.
    func setPlace(_ place: SidebarCardPlace)
}

extension SidebarSurfaceIsland {
    public var contentWidth: CGFloat { 0 }
    public var overlayHeight: CGFloat { 0 }
    public var previewHeight: CGFloat { 0 }
    public var zoom: CGFloat { 1 }
    public func setPointerInside(_ inside: Bool) {}
    public var onDrag: ((SidebarCardDrag) -> Void)? {
        get { nil }
        set {}
    }
    public func setPlace(_ place: SidebarCardPlace) {}
}

/// Where the sidebar's Updated card rests: at the bottom card slot (its first place), or at the top
/// of the list, under the titlebar row (Leo 2026-11-07: "you can drag that up to the top").
public enum SidebarCardAnchor: String, Sendable {
    case top, bottom
}

/// One report of the Updated card's drag, in points: how far the page holds it from where it rests,
/// and on its release, the anchor it settles at.
public struct SidebarCardDrag: Equatable, Sendable {
    public var offset: CGPoint
    public var drop: SidebarCardAnchor?

    public init(offset: CGPoint, drop: SidebarCardAnchor? = nil) {
        self.offset = offset
        self.drop = drop
    }
}

/// Where the Updated card rests and the room, in points, from its top edge up to the farthest it may
/// rest (`above`) and from its bottom edge down (`below`).
public struct SidebarCardPlace: Equatable, Sendable {
    public var anchor: SidebarCardAnchor
    public var above: CGFloat
    public var below: CGFloat

    public init(anchor: SidebarCardAnchor, above: CGFloat, below: CGFloat) {
        (self.anchor, self.above, self.below) = (anchor, above, below)
    }
}

/// Makes the update surfaces (set by the App on each sidebar).
@MainActor
public protocol SidebarUpdateSurfaces: AnyObject {
    func island(_ kind: SidebarUpdateSurfaceKind) -> any SidebarSurfaceIsland
}

/// The popover's content: the ready surface, and the pointer coming into it
/// (a pending close is called off) and leaving it (the popover then closes
/// unless the pointer is on the card, or on its way there).
final class SidebarPopoverIslandHost: NSView {
    var onPointerEnter: (() -> Void)?
    var onPointerExit: (() -> Void)?
    private var tracking: NSTrackingArea?

    /// The host's size in a hover card (the card fits its body).
    private var heightConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    /// The widest the host gets (the menu width); a page that reports its own width is narrower.
    let maxWidth: CGFloat

    init(width: CGFloat) {
        maxWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        let height = heightAnchor.constraint(equalToConstant: 1)
        let widthConstraint = widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([widthConstraint, height])
        heightConstraint = height
        self.widthConstraint = widthConstraint
    }

    /// Sizes the host `height` tall (the page's height, capped to its window) and `width` wide
    /// (the page's own width, at most ``maxWidth``; 0 is the full width).
    func fit(height: CGFloat, width: CGFloat = 0) {
        heightConstraint?.constant = max(1, height)
        widthConstraint?.constant = width > 0 ? min(maxWidth, ceil(width)) : maxWidth
    }

    /// Moves the surface's page view in (it waits parked in the card while
    /// the popover is closed, so it has loaded and measured before it shows).
    func adopt(_ island: any SidebarSurfaceIsland) {
        guard island.view.superview !== self else { return }
        island.view.removeFromSuperview()
        island.view.alphaValue = 1
        island.view.frame = bounds
        island.view.autoresizingMask = [.width, .height]
        addSubview(island.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExit?()
    }
}

/// Where a surface's page waits while its popover is closed: in the window
/// (so the page loads and measures), invisible, and never under the pointer.
/// Its owner places it outside the card's bounds, so the page's own tracking
/// areas (cursor, hover) see no pointer; it is not in the accessibility tree.
final class SidebarIslandParking: NSView {
    /// Far outside any card: the parked page's visible rect is empty.
    static let offscreenX: CGFloat = -10_000

    override init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityChildren() -> [Any]? { [] }
}

#if DEBUG
extension SidebarViewComponents {
    /// Proofs (`debug.update_surfaces`): opens the staged card's highlights
    /// popover as a hover would; whether it shows.
    public func debugShowUpdateHighlights() -> [String: String] {
        updateCardView.showNotes()
        return ["shown": String(updateCardView.notesAreShown),
                "card": String(updateCardView.card != nil),
                "highlights": String(updateCardView.highlights != nil),
                "height": String(Double(updateCardView.highlights?.contentHeight ?? -1)),
                "parked": String(updateCardView.highlights?.view.superview === updateCardView.parking),
                "window": String(updateCardView.window != nil),
                "hiddenAncestor": String(updateCardView.isHiddenOrHasHiddenAncestor)]
    }

    /// Proofs (`debug.update_surfaces {action: "hover-updated"}`): puts the pointer on the
    /// Updated card as a hover would (its x shows; its look's changes open, beside the sidebar or
    /// in the card) and opens the popover now, without the rest; what shows.
    public func debugHoverUpdatedCard() -> [String: String] {
        updatedCardView.setHovered(true)
        updatedCardView.notes.show(force: true)
        return ["look": updatedCardView.previewMode.rawValue,
                "notesShown": String(updatedCardView.notes.isShown),
                "notesPage": String(updatedCardView.notes.island != nil),
                "notesHeight": String(Double(updatedCardView.notes.island?.contentHeight ?? -1)),
                "updatedCard": String(updatedCardView.card != nil)]
    }

    /// Proofs (`debug.update_surfaces {action: "state"}`): which update
    /// pages this sidebar holds now (each is a web page, cx-asynu).
    public func debugUpdateSurfaceState() -> [String: String] {
        ["card": String(updateCardView.card != nil),
         "highlights": String(updateCardView.highlights != nil),
         "updatedCard": String(updatedCardView.card != nil),
         "updatedPage": String(updatedCardView.island != nil),
         "updatedHeight": String(Double(updatedCardView.height)),
         "updatedCloseShown": String(updatedCardView.closeShown)]
    }

    /// Proofs (`debug.update_surfaces`): the Updated card's x while the card shows.
    public var debugUpdatedCloseButton: NSView? {
        updatedCardView.isHiddenOrHasHiddenAncestor ? nil : updatedCardView.closeButton
    }

    /// Proofs (`debug.update_surfaces`): the Updated card's page view while it shows, for a
    /// window hit test at its x.
    public var debugUpdatedPageView: NSView? {
        updatedCardView.isHiddenOrHasHiddenAncestor ? nil : updatedCardView.island?.view
    }
}
#endif
