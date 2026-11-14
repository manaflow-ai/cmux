import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The "cmux Updated!" card's changes beside the sidebar (``UpdatedCardPreviewMode/beside``, the
/// shipped look): resting on the card opens the update's changes in the app's one hover card window,
/// to the side of the sidebar, as the staged update card's highlights open.
///
/// Lawrence 2026-11-07, on the list that grew up out of the bottom card over the sidebar's rows: "i
/// dont like how it expands upwards, also it looks very bad". The card no longer grows: it stays the
/// composer's height in its slot, and the popover beside it is menu-wide, so each change's title
/// reads whole.
///
/// The page (`#/surface/updated-notes`) waits parked in the card while the popover is closed, so it
/// has loaded and measured before it shows. The popover opens after a short rest on the card (a
/// pointer on its way past the bottom of the sidebar opens nothing), stays while the pointer travels
/// to it, and closes a moment after the pointer left both, unless the pointer is still on its way.
@MainActor
final class SidebarUpdatedNotesPopover {
    /// The popover's card in the app's one hover card window.
    static let id = HoverTargetID("sidebar:updated-notes")
    /// How long the pointer rests on the card before the popover opens.
    static var openDelay: Duration { .milliseconds(280) }
    /// How long the popover waits after the pointer left the card or the popover before it closes.
    static var closeDelay: Duration { .milliseconds(250) }
    /// The longest the way between the card and the popover keeps it open (a slow hand).
    static var corridorLimit: Duration { .milliseconds(1200) }
    /// The popover is at most this share of its window's height; the page scrolls inside it.
    static var maxHeightFraction: CGFloat { 0.6 }

    /// Makes the page (``SidebarUpdatedCardHost/surfaces``).
    var surfaces: (any SidebarUpdateSurfaces)?
    /// The app's one hover card coordinator (the sidebar list's).
    var hoverCards: @MainActor () -> HoverCardCoordinator? = { nil }
    /// The pointer on screen (tests place it).
    var screenPointer: () -> CGPoint = { NSEvent.mouseLocation }
    /// The changes' page, while the card shows in a look that opens it.
    private(set) var island: (any SidebarSurfaceIsland)?
    let host = SidebarPopoverIslandHost(width: SidebarUpdateCardView.popoverWidth)
    private let parking = SidebarIslandParking()
    private let openTimer = DemandTimer(owner: "sidebar.updated-card.notes-open")
    private let closeTimer = DemandTimer(owner: "sidebar.updated-card.notes-close")
    private var closeWaited: Duration = .zero
    private weak var card: NSView?
    private var cardHovered = false

    init() {
        host.onPointerEnter = { [weak self] in self?.cancelClose() }
        host.onPointerExit = { [weak self] in self?.pointerLeftNotes() }
    }

    /// Makes the page and parks it in `card` when `enabled` (the look opens the popover), else
    /// closes the popover and its page.
    func prepare(in card: NSView, enabled: Bool) {
        self.card = card
        guard enabled, let surfaces else { return tearDown() }
        guard island == nil else { return }
        let page = surfaces.island(.updatedNotes)
        page.onAction = { [weak self] in self?.hide() }
        page.onHeightChange = { [weak self] in self?.pageResized() }
        island = page
        park()
    }

    /// Closes the popover and its page (the card went away, or the look has no popover).
    func tearDown() {
        hide()
        island?.close()
        island?.view.removeFromSuperview()
        island = nil
        parking.removeFromSuperview()
    }

    /// The pointer came onto the card (the popover opens after ``openDelay``) or left it (the
    /// popover closes unless the pointer went into it, or is on its way there).
    func cardHovered(_ hovered: Bool) {
        cardHovered = hovered
        guard island != nil else { return }
        if hovered {
            cancelClose()
            guard !isShown else { return }
            openTimer.schedule(after: Self.openDelay) { @MainActor [weak self] in self?.show() }
            return
        }
        openTimer.cancel()
        guard isShown, !pointerIsOverNotes() else { return }
        scheduleClose()
    }

    /// The popover shows (or is opening).
    var isShown: Bool { hoverCards()?.isShowingOwned(Self.id) == true }

    /// The popover's card on screen while it shows.
    var frame: CGRect? { hoverCards()?.ownedCardFrame(Self.id) }

    /// Opens the popover beside the card, toward the content. No-op unless the pointer is still on
    /// the card and the page has drawn.
    func show(force: Bool = false) {
        guard force || cardHovered, let card, let window = card.window, !card.isHiddenOrHasHiddenAncestor,
              let island, island.contentHeight > 0, let cards = hoverCards() else { return }
        cancelClose()
        host.adopt(island)
        host.fit(height: height(for: island.contentHeight, in: window), width: island.contentWidth)
        let anchor = window.convertToScreen(card.convert(card.bounds, to: nil))
        let content = HoverCardBody(view: host, placement: .beside, themeAnchor: card, applyTheme: {})
        cards.presentOwned(Self.id, body: content, anchor: anchor, parent: window, interactive: true) { [weak self] in
            self?.ended()
        }
    }

    /// Closes the popover (an action in it, the card hiding).
    func hide() {
        openTimer.cancel()
        cancelClose()
        guard isShown else { return }
        hoverCards()?.endOwned(Self.id)
    }

    private func ended() {
        cancelClose()
        park()
    }

    /// The page waits in the card's view tree, transparent and outside the card's bounds, so it
    /// loads and reports its height while the popover is closed.
    private func park() {
        guard let card, let island, island.view.superview !== parking else { return }
        if parking.superview !== card { card.addSubview(parking, positioned: .below, relativeTo: nil) }
        parking.frame = NSRect(x: SidebarIslandParking.offscreenX, y: 0, width: host.maxWidth, height: max(1, island.contentHeight))
        island.view.removeFromSuperview()
        island.view.frame = parking.bounds
        island.view.autoresizingMask = [.width, .height]
        parking.addSubview(island.view)
    }

    private func pageResized() {
        guard let island, island.contentHeight > 0 else { return }
        if !isShown {
            parking.frame.size.height = max(1, island.contentHeight)
            return
        }
        guard let window = card?.window else { return }
        host.fit(height: height(for: island.contentHeight, in: window), width: island.contentWidth)
        hoverCards()?.refitOwned(Self.id)
    }

    private func height(for content: CGFloat, in window: NSWindow) -> CGFloat {
        min(content, max(120, floor(window.frame.height * Self.maxHeightFraction)))
    }

    // MARK: Close

    private var cardScreenFrame: CGRect? {
        guard let card, let window = card.window else { return nil }
        return window.convertToScreen(card.convert(card.bounds, to: nil))
    }

    private func pointerIsOverNotes() -> Bool {
        guard let frame else { return false }
        return frame.insetBy(dx: -Metrics.space2, dy: -Metrics.space2).contains(screenPointer())
    }

    /// The band between the card's middle and the popover, as tall as both together.
    private func pointerIsOnTheWay() -> Bool {
        guard let notes = frame, let card = cardScreenFrame else { return false }
        let point = screenPointer()
        if card.insetBy(dx: -Metrics.space1, dy: -Metrics.space1).contains(point) { return true }
        let minX = notes.minX >= card.maxX ? card.midX : notes.maxX
        let maxX = notes.minX >= card.maxX ? notes.minX : card.midX
        let corridor = CGRect(x: minX, y: min(card.minY, notes.minY), width: max(0, maxX - minX),
                              height: max(card.maxY, notes.maxY) - min(card.minY, notes.minY))
        return corridor.contains(point)
    }

    private func pointerLeftNotes() {
        guard !cardHovered else { return }
        scheduleClose()
    }

    private func scheduleClose() {
        guard isShown else { return }
        closeWaited = .zero
        armClose()
    }

    private func armClose() {
        closeTimer.schedule(after: Self.closeDelay) { @MainActor [weak self] in self?.closeFired() }
    }

    /// One wait passed: stay (pointer on the card or in the popover), wait again (on its way, under
    /// the cap), or close.
    private func closeFired() {
        closeWaited += Self.closeDelay
        if cardHovered { return }
        if let notes = frame, notes.contains(screenPointer()) { return }
        if pointerIsOnTheWay() || pointerIsOverNotes(), closeWaited < Self.corridorLimit { return armClose() }
        hoverCards()?.endOwned(Self.id)
    }

    private func cancelClose() {
        closeTimer.cancel()
        closeWaited = .zero
    }
}
