import AppKit
import CmuxNextDesign

/// The "cmux Updated!" card's slot view: the sidebar cards' glass, the updated
/// surface over it, sized to the page's height, and the card's x. Hidden without
/// a card or a surface.
///
/// The glass is native (``CardSurfaceView``, the Update Ready, Now Playing and
/// notice cards' own), under the transparent page, which draws only the words
/// (Leo 2026-10-30: "I don't like the non-glassness"). A web page's CSS glass
/// sees nothing of the sidebar behind its view, so the page alone could paint
/// only a flat fill. Under Reduce Transparency the surface is the opaque
/// elevated fill, as every card's.
///
/// The x is native, over the page's top right, shown while the pointer is on
/// the card (Lawrence 2026-10-23: "i cant X this out anymore even when hovering
/// on it"). It was the page's own button: WebKit tracks the pointer and takes a
/// first click only in the key window, and since the agent chat, New Tab and
/// Home run in Chromium (69a51bf63be, 95b8716297c) a Chromium page's own child
/// window holds the key while the person works there, so the page never showed
/// its x and ate the click. A native tracking area and a button that takes the
/// first click work whichever of the app's windows has the key, as the media
/// card's x does.
final class SidebarUpdatedCardHost: NSView {
    private(set) var card: SidebarUpdatedCard?
    /// The page's height changed: the sidebar lays the slot out again.
    var onHeightChange: (() -> Void)?
    /// The card's x (u2441): the slot sends `.dismissUpdated`, as every card's x sends its intent.
    var onDismiss: (() -> Void)?
    /// The card's glass, under the page.
    let surface = CardSurfaceView()
    /// The x: shown while the pointer is on the card.
    let closeButton = SidebarIconButton(icon: .actionClose, pointSize: { 9 }, label: "")
    /// The pointer is on the card: its x shows.
    private(set) var isHovered = false
    private var hoverArea: NSTrackingArea?
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
            // Under the x: the page never covers it.
            addSubview(island.view, positioned: .below, relativeTo: closeButton)
            island.onHeightChange = { [weak self] in self?.onHeightChange?() }
            island.onDismiss = { [weak self] in self?.onDismiss?() }
        }
    }

    /// The card's corner: the page's own card radius (`.wn-card`'s 12 px, updateSurfaces.css), so the
    /// glass keeps the card's shape. Space 5 is 12 pt at the default density.
    static var cornerRadius: CGFloat { Metrics.space5 }

    /// The x's side and its inset from the card's top right (the page's own x stood there).
    static let closeSide: CGFloat = 18
    static let closeInset = NSSize(width: 8, height: 7)

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        setAccessibilityElement(false)
        addSubview(surface)
        closeButton.showsLabelToolTip = false
        closeButton.takesKeyFocus = true
        closeButton.takesFirstClick = true
        closeButton.setAccessibilityIdentifier("cmux.sidebar.updated.close")
        closeButton.onPress = { [weak self] in self?.onDismiss?() }
        closeButton.isHidden = true
        closeButton.alphaValue = 0
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    /// Shows the card (the page draws its text), or hides the view and
    /// closes its page.
    func configure(_ card: SidebarUpdatedCard?) {
        guard card != self.card else { return }
        self.card = card
        closeButton.label = card?.dismissLabel ?? ""
        if card != nil, island == nil { island = surfaces?.island(.updated) }
        if card == nil {
            if let island {
                // The card went away (dismissed): its page goes too (cx-asynu).
                island.close()
                self.island = nil
            }
            // A card that comes back starts without its x until the pointer moves onto it.
            isHovered = false
            setHoverShown(closeButton, false, fades: false)
        }
        isHidden = card == nil || island == nil
    }

    /// The card's height: the page's content height (0 until it drew).
    var height: CGFloat { card == nil ? 0 : island?.contentHeight ?? 0 }

    /// Shows the x while the pointer is on the card, with the hover-reveal fade (instant under Reduce Motion).
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        setHoverShown(closeButton, hovered && card != nil, fades: window != nil)
    }

    /// Whether the x shows now (proofs).
    var closeShown: Bool { !closeButton.isHidden && closeButton.alphaValue > 0 }

    override func layout() {
        super.layout()
        surface.frame = bounds
        surface.cornerRadius = Self.cornerRadius
        let side = Self.closeSide
        closeButton.frame = NSRect(x: bounds.width - Self.closeInset.width - side, y: Self.closeInset.height,
                                   width: side, height: side).integral
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // Active in the active app, not only the key window: a Chromium page's window may hold the key.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(false)
    }
}
