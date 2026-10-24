public import AppKit

/// The two update surfaces the What's New design draws in React
/// (cx-urd.61.2): the staged update's highlights in the card's hover
/// popover, and the "cmux Updated!" card after an update.
public enum SidebarUpdateSurfaceKind: String, Sendable {
    case ready, updated
}

/// One React surface the App mounts in a sidebar host (a page view). The
/// page reports its content height; the host sizes itself to it.
@MainActor
public protocol SidebarSurfaceIsland: AnyObject {
    var view: NSView { get }
    /// The content's height in points; 0 until the page has drawn.
    var contentHeight: CGFloat { get }
    /// The content height changed.
    var onHeightChange: (() -> Void)? { get set }
    /// The page ran one of its actions (the popover then closes).
    var onAction: (() -> Void)? { get set }
    /// The page's x: the host sends its card's dismiss intent (one path for every card's x).
    var onDismiss: (() -> Void)? { get set }
    /// The sidebar went away: the page cancels its subscriptions.
    func close()
}

/// Makes the update surfaces (set by the App on each sidebar).
@MainActor
public protocol SidebarUpdateSurfaces: AnyObject {
    func island(_ kind: SidebarUpdateSurfaceKind) -> any SidebarSurfaceIsland
}

/// The popover's content: the ready surface, and the pointer coming into it
/// (a pending close is called off) and leaving it (the popover then closes
/// after a short delay unless the pointer is back on it or the card).
final class SidebarPopoverIslandHost: NSView {
    var onPointerEnter: (() -> Void)?
    var onPointerExit: (() -> Void)?
    private var tracking: NSTrackingArea?

    /// The host's height in a hover card (the card fits its body); its width is fixed.
    private var heightConstraint: NSLayoutConstraint?

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        let height = heightAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: width), height])
        heightConstraint = height
    }

    /// Sizes the host `height` tall (the page's height, capped to its window).
    func fit(height: CGFloat) {
        heightConstraint?.constant = max(1, height)
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
