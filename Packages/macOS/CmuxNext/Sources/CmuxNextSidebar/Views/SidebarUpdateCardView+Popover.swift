import AppKit
import CmuxNextDesign

// UPDATE-CARD: the highlights popup (the React ready surface, cx-urd.61.2,
// in the app's one hover card window) opens while the pointer is
// anywhere over the card and stays while the pointer travels to it, so it can
// be scrolled and "See all changes" clicked. Leaving the card or the popup
// closes it after a short delay unless the pointer is back on either, or is
// still on its way across the corridor between them (Leo 2026-10-19: it
// closed at once unless the pointer left the card straight to the right, the
// only exit that landed in the popup's 8 pt margin). The highlights were read
// when the update staged, so opening it reads no network.
//
// One card (Lawrence 2026-10-20: "only one card, one offer card, appears at any point in time"):
// the popup is the app's one hover card window (`HoverCardCoordinator.presentOwned`), not a
// window of its own. Opening it while a workspace card shows morphs that card into it; a
// workspace row the pointer reaches next takes the card back, morphing again.
extension SidebarUpdateCardView {
    /// The highlights' card in the app's one hover card window.
    static let notesID = HoverTargetID("sidebar:update-highlights")

    /// Opens the popup beside the card (toward the content, away from the
    /// window edge). No-op without a card or a window. A popup that is still
    /// closing (the pointer left and came back) opens again.
    func showNotes() {
        cancelNotesClose()
        guard card != nil, let highlights, highlights.contentHeight > 0, let window, !isHiddenOrHasHiddenAncestor,
              let cards = hoverCards() else { return }
        let host = notesHost
        wireNotes(highlights)
        host.adopt(highlights)
        host.fit(height: notesHeight(for: highlights.contentHeight))
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let body = HoverCardBody(view: host, placement: .beside, themeAnchor: self, applyTheme: {})
        cards.presentOwned(Self.notesID, body: body, anchor: anchor, parent: window, interactive: true) { [weak self] in
            self?.notesEnded()
        }
    }

    /// The highlights' card left the window (closed and faded out, or a workspace card took it):
    /// the page goes back to wait in the card.
    private func notesEnded() {
        notesPinned = false
        cancelNotesClose()
        // A close under the pointer (the app resigning active) does not reopen on the next move.
        if isHovered { notesDismissedWhileHovered = true }
        parkHighlights()
    }

    /// Menu width: the popover type every cmux popover uses (320-360 pt).
    static var popoverWidth: CGFloat { 340 }

    /// The popup is at most this share of its window's height; the page scrolls inside it.
    static var popoverMaxHeightFraction: CGFloat { 0.6 }

    /// A pinned popup (a click on the card) may grow to this share of its window's height.
    static var pinnedMaxHeightFraction: CGFloat { 0.85 }

    /// How long the popup waits after the pointer left the card or the popup before it closes.
    static var notesCloseDelay: Duration { .milliseconds(250) }

    /// The longest the corridor between the card and the popup keeps it open (a slow hand).
    static var notesCorridorLimit: Duration { .milliseconds(1200) }

    /// The popup's height for a page `contentHeight` tall: capped to
    /// ``popoverMaxHeightFraction`` of the window (the page scrolls past it).
    func notesHeight(for contentHeight: CGFloat) -> CGFloat {
        guard let window else { return contentHeight }
        let fraction = notesPinned ? Self.pinnedMaxHeightFraction : Self.popoverMaxHeightFraction
        return min(contentHeight, max(120, floor(window.frame.height * fraction)))
    }

    /// A click on the card: pins the preview open and taller, or closes a pinned one.
    func toggleNotesPinned() {
        guard card != nil else { return }
        if notesPinned {
            hideNotes()
            return
        }
        notesPinned = true
        notesDismissedWhileHovered = false
        if notesAreShown, let highlights, highlights.contentHeight > 0 {
            cancelNotesClose()
            notesHost.fit(height: notesHeight(for: highlights.contentHeight))
            hoverCards()?.refitOwned(Self.notesID)
        } else {
            showNotes()
            // Nothing to show yet (no page height, no window): a later hover opens an unpinned one.
            if !notesAreShown { notesPinned = false }
        }
    }

    /// The popup shows (or is opening).
    var notesAreShown: Bool { hoverCards()?.isShowingOwned(Self.notesID) == true }

    /// The window the popup shows in while it shows (the app's one hover card window).
    var notesPanel: NSWindow? { notesAreShown ? hoverCards()?.cardWindow : nil }

    /// The popup's card on screen while it shows.
    var notesFrame: CGRect? { hoverCards()?.ownedCardFrame(Self.notesID) }

    /// Closes the popup (Hide, an action, the card going away). A close under the pointer is
    /// noted as it starts, so a move during its fade does not reopen it.
    func hideNotes() {
        notesPinned = false
        cancelNotesClose()
        guard notesAreShown else { return }
        if isHovered { notesDismissedWhileHovered = true }
        hoverCards()?.endOwned(Self.notesID)
    }

    /// The page's host hears the pointer and its height.
    private func wireNotes(_ highlights: any SidebarSurfaceIsland) {
        notesHost.onPointerExit = { [weak self] in self?.pointerLeftNotes() }
        notesHost.onPointerEnter = { [weak self] in self?.cancelNotesClose() }
        highlights.onHeightChange = { [weak self, weak highlights] in
            guard let self, let highlights, highlights.contentHeight > 0 else { return }
            self.notesHost.fit(height: self.notesHeight(for: highlights.contentHeight))
            self.hoverCards()?.refitOwned(Self.notesID)
        }
    }

    /// Whether `point` (screen, default the pointer now) is over the popup,
    /// with a small margin for the gap between card and popup.
    func pointerIsOverNotes(_ point: CGPoint? = nil) -> Bool {
        guard let notes = notesFrame else { return false }
        return notes.insetBy(dx: -Metrics.space2, dy: -Metrics.space2).contains(point ?? screenPointer())
    }

    /// The card's frame on screen.
    var cardScreenFrame: CGRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    /// Whether `point` (screen, default the pointer now) is over the card.
    func pointerIsOverCard(_ point: CGPoint? = nil) -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        return cardScreenFrame?.insetBy(dx: -Metrics.space1, dy: -Metrics.space1).contains(point ?? screenPointer()) ?? false
    }

    /// Whether `point` is on the way between the card and the popup: the
    /// band from the card's edge facing the popup to the popup, as tall as
    /// both together (a diagonal toward a tall popup stays inside it).
    func pointerIsInNotesCorridor(_ point: CGPoint? = nil) -> Bool {
        guard let notes = notesFrame, let card = cardScreenFrame else { return false }
        let minX = notes.minX >= card.maxX ? card.midX : notes.maxX
        let maxX = notes.minX >= card.maxX ? notes.minX : card.midX
        let corridor = CGRect(x: minX, y: min(card.minY, notes.minY), width: max(0, maxX - minX),
                              height: max(card.maxY, notes.maxY) - min(card.minY, notes.minY))
        return corridor.contains(point ?? screenPointer())
    }

    /// The pointer left the card or the popup: close after ``notesCloseDelay``
    /// unless it is back on either by then. While it is in the corridor
    /// between them, or in the small margin around either, the close waits
    /// again, up to ``notesCorridorLimit`` in all.
    func scheduleNotesClose() {
        guard notesAreShown, !notesPinned else { return }
        notesCloseWaited = .zero
        armNotesClose()
    }

    private func armNotesClose() {
        notesCloseTimer.schedule(after: Self.notesCloseDelay) { @MainActor [weak self] in
            self?.notesCloseFired()
        }
    }

    /// One wait passed: stay (pointer on the card or inside the popup), wait
    /// again (on the way, under the cap), or close.
    func notesCloseFired() {
        // DemandTimer can still run a check that was cancelled after it claimed its fire: harmless,
        // it re-reads the pointer; it only counts one more wait toward the limit.
        notesCloseChecks &+= 1
        if notesPinned { return }
        notesCloseWaited += Self.notesCloseDelay
        if isHovered && !isHiddenOrHasHiddenAncestor { return }
        if let notes = notesFrame, notes.contains(screenPointer()) { return }
        let onTheWay = pointerIsInNotesCorridor() || pointerIsOverCard() || pointerIsOverNotes()
        if onTheWay, notesCloseWaited < Self.notesCorridorLimit { return armNotesClose() }
        hoverCards()?.endOwned(Self.notesID)
    }

    func cancelNotesClose() {
        notesCloseTimer.cancel()
        notesCloseWaited = .zero
    }

    /// The pointer left the popup: it closes after the delay unless the
    /// pointer comes back to it or the card.
    func pointerLeftNotes() {
        guard !pointerIsOverCard() else { return }
        scheduleNotesClose()
    }
}
