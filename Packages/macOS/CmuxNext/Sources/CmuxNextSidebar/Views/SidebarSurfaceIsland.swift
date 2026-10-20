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

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 1))
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

/// The "cmux Updated!" card's slot view: the updated surface, sized to the
/// page's height. Hidden without a card or a surface.
final class SidebarUpdatedCardHost: NSView {
    private(set) var card: SidebarUpdatedCard?
    /// The page's height changed: the sidebar lays the slot out again.
    var onHeightChange: (() -> Void)?
    /// The page's x (u2441): the slot sends `.dismissUpdated`, as every card's x sends its intent.
    var onDismiss: (() -> Void)?
    /// Makes ``island`` once a card shows (a web page; none at launch without one).
    var surfaces: (any SidebarUpdateSurfaces)? {
        didSet {
            island?.close()
            island = card == nil ? nil : surfaces?.island(.updated)
            isHidden = card == nil || island == nil
        }
    }
    var island: (any SidebarSurfaceIsland)? {
        didSet {
            oldValue?.view.removeFromSuperview()
            guard let island else { return }
            island.view.frame = bounds
            island.view.autoresizingMask = [.width, .height]
            addSubview(island.view)
            island.onHeightChange = { [weak self] in self?.onHeightChange?() }
            island.onDismiss = { [weak self] in self?.onDismiss?() }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    /// Shows the card (the page draws its text), or hides the view and
    /// closes its page.
    func configure(_ card: SidebarUpdatedCard?) {
        guard card != self.card else { return }
        self.card = card
        if card != nil, island == nil { island = surfaces?.island(.updated) }
        if card == nil, let island {
            // The card went away (dismissed): its page goes too (cx-asynu).
            island.close()
            self.island = nil
        }
        isHidden = card == nil || island == nil
    }

    /// The card's height: the page's content height (0 until it drew).
    var height: CGFloat { card == nil ? 0 : island?.contentHeight ?? 0 }
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
         "updatedHeight": String(Double(updatedCardView.height))]
    }
}
#endif
