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
/// elevated fill, as every card's. Its veil takes the theme's glass tint
/// (``CardSurfaceView/takesThemeTint``): over a themed sidebar the neutral
/// gray read as an unthemed card (Leo 2026-11-02).
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
            pageReported = false
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
            island.onHeightChange = { [weak self] in self?.pageDidReportHeight() }
            island.onDismiss = { [weak self] in self?.onDismiss?() }
        }
    }

    /// The height the card's page last reported, kept across launches: a relaunch after an update
    /// lays the card out at it in its first frame instead of making room once the page has drawn
    /// (Leo 2026-11-04: "i feel like the restarted after nightly update does too many layout
    /// shifts/flicker renderings"). The card's words and its shape change little between builds, so
    /// the previous build's height is the guess when this build's card has not drawn yet.
    static let rememberedHeightKey = "cmux.sidebar.updatedCard.height"
    static var rememberedHeight: CGFloat { max(0, CGFloat(UserDefaults.standard.double(forKey: rememberedHeightKey))) }

    /// The card's next height lands at once: its first layout (at the remembered height) and the
    /// page's first report (its real one). The list then has its final room in the frame the card
    /// shows, never on a spring; later changes (the notes of a new build) still spring.
    private(set) var landsAtOnce = false
    /// The page has reported a height since the card showed.
    private var pageReported = false

    /// The sidebar laid the card out at its height without motion.
    func landed() { landsAtOnce = false }

    private func pageDidReportHeight() {
        if !pageReported { (pageReported, landsAtOnce) = (true, true) }
        if let height = island?.contentHeight, height > 0, height != Self.rememberedHeight {
            UserDefaults.standard.set(Double(height), forKey: Self.rememberedHeightKey)
        }
        onHeightChange?()
    }

    /// The card's sizes at the sidebar's density (Lawrence 2026-11-01: "the card must reflect my
    /// compactness level"): the page reads the same ones (`--cmux-sidebar-card-*`, WebTheme).
    static var metrics: SidebarCardMetrics { SidebarRowTokens.current.card }
    /// The card's corner: the page's own card radius, so the glass keeps the card's shape.
    static var cornerRadius: CGFloat { metrics.cornerRadius }

    /// The x's side and its inset from the card's top right: on the title line, inside the padding.
    static var closeSide: CGFloat { metrics.closeSide }
    static var closeInset: NSSize {
        let m = metrics
        return NSSize(width: max(m.paddingX - 2, 0), height: max(m.paddingY - 2, 0))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        setAccessibilityElement(false)
        // The theme's surface, not the neutral gray (Leo 2026-11-02: "why is the update thing unthemed").
        surface.takesThemeTint = true
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
        // A card that shows (at launch, after the update) takes its room at once.
        if card != nil, self.card == nil { (landsAtOnce, pageReported) = (true, false) }
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

    /// The card's height: the page's content height once it has reported one (0 for a page with
    /// nothing to show, which hides the card), and until then the height it last reported
    /// (``rememberedHeight``; 0 when it never drew), so the room is there from the first frame and
    /// the words fill in where they stay.
    var height: CGFloat {
        guard card != nil, let island else { return 0 }
        return pageReported ? island.contentHeight : Self.rememberedHeight
    }

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
