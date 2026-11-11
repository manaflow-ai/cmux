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
/// pointer on its way past the bottom of the sidebar opens nothing) and closes the moment the pointer
/// is on neither the card nor the popover (Aziz 2026-11-10: the popover "lingers a few seconds" after
/// the pointer left both). It used to wait 250 ms, then keep waiting up to 1.2 s more while the
/// pointer was anywhere in the band from the card's middle to the popover and as tall as both, which
/// covers the sidebar's rows beside the card: a pointer that left for the rows kept it open. The card
/// and the popover touch (`HoverCardPanel` puts a `.beside` card one pixel from its anchor), so the
/// way between them is that seam alone: only there does the close wait, a frame at a time.
@MainActor
final class SidebarUpdatedNotesPopover {
    /// The popover's card in the app's one hover card window.
    static let id = HoverTargetID("sidebar:updated-notes")
    /// How long the pointer rests on the card before the popover opens.
    static var openDelay: Duration { .milliseconds(280) }
    /// How often the close looks again while the pointer is in the seam between the card and the popover.
    static var seamRecheck: Duration { .milliseconds(16) }
    /// The longest a pointer resting in the seam keeps the popover open.
    static var seamLimit: Duration { .milliseconds(250) }
    /// How far past the card's edge, toward the popover, the seam reaches (the popover's one-pixel gap
    /// and a hand that overshoots it a little).
    static var seamWidth: CGFloat { 4 }
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
        closeIfLeftBoth()
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

    /// Where the pointer is for the close (``closeStep(pointer:card:notes:)``).
    enum CloseStep: Equatable {
        /// On the card or the popover: it stays.
        case stay
        /// In the seam between them, on its way: it looks again in a frame.
        case wait
        /// On neither: it closes now.
        case close
    }

    /// What the popover does with the pointer at `pointer` (screen points), the card at `card` and the
    /// popover at `notes`.
    static func closeStep(pointer: CGPoint, card: CGRect, notes: CGRect) -> CloseStep {
        if card.contains(pointer) || notes.contains(pointer) { return .stay }
        // The strip between the card's edge and the popover's facing edge, as tall as both overlap.
        let right = notes.minX >= card.midX
        let minX = right ? card.maxX : notes.maxX
        let maxX = right ? notes.minX : card.minX
        let seam = CGRect(x: minX - seamWidth / 2, y: max(card.minY, notes.minY),
                          width: max(0, maxX - minX) + seamWidth, height: max(0, min(card.maxY, notes.maxY) - max(card.minY, notes.minY)))
        return seam.contains(pointer) ? .wait : .close
    }

    private var cardScreenFrame: CGRect? {
        guard let card, let window = card.window else { return nil }
        return window.convertToScreen(card.convert(card.bounds, to: nil))
    }

    /// The pointer left the popover: it closes unless the pointer went onto the card. Read from the
    /// geometry, not ``cardHovered``: the card's hover may hear the pointer arrive after this does.
    private func pointerLeftNotes() {
        guard !cardHovered else { return }
        closeIfLeftBoth()
    }

    /// Closes the popover now when the pointer is on neither the card nor the popover; in the seam
    /// between them it looks again each frame, up to ``seamLimit``.
    private func closeIfLeftBoth(waited: Duration = .zero) {
        closeTimer.cancel()
        guard isShown, let notes = frame else { return }
        let step = cardScreenFrame.map { Self.closeStep(pointer: screenPointer(), card: $0, notes: notes) } ?? .close
        switch step {
        case .stay: return
        case .wait where waited < Self.seamLimit:
            closeTimer.schedule(after: Self.seamRecheck) { @MainActor [weak self] in
                guard let self, !self.cardHovered else { return }
                self.closeIfLeftBoth(waited: waited + Self.seamRecheck)
            }
        case .wait, .close:
            hoverCards()?.endOwned(Self.id)
        }
    }

    private func cancelClose() {
        closeTimer.cancel()
    }
}
