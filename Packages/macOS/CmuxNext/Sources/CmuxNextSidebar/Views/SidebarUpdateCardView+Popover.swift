import AppKit
import CmuxNextDesign

// UPDATE-CARD: the highlights popup (the React ready surface, cx-urd.61.2,
// in the themed popup of SidebarUpdateNotesPanel) opens while the pointer is
// anywhere over the card and stays while the pointer travels to it, so it can
// be scrolled and "See all changes" clicked. Leaving the card or the popup
// closes it after a short delay unless the pointer is back on either, or is
// still on its way across the corridor between them (Leo 2026-10-19: it
// closed at once unless the pointer left the card straight to the right, the
// only exit that landed in the popup's 8 pt margin). The highlights were read
// when the update staged, so opening it reads no network.
extension SidebarUpdateCardView {
    /// Opens the popup beside the card (toward the content, away from the
    /// window edge). No-op without a card or a window. A popup that is still
    /// closing (the pointer left and came back) opens again.
    func showNotes() {
        cancelNotesClose()
        guard card != nil, let highlights, highlights.contentHeight > 0, let window, !isHiddenOrHasHiddenAncestor else { return }
        let panel = notesPanel ?? makeNotesPanel(highlights)
        notesPanel = panel
        panel.host.adopt(highlights)
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        panel.present(beside: anchor, height: notesHeight(for: highlights.contentHeight), parent: window, themeAnchor: self)
    }

    /// Menu width: the popover type every cmux popover uses (320-360 pt).
    static var popoverWidth: CGFloat { 340 }

    /// The popup is at most this share of its window's height; the page scrolls inside it.
    static var popoverMaxHeightFraction: CGFloat { 0.6 }

    /// How long the popup waits after the pointer left the card or the popup before it closes.
    static var notesCloseDelay: Duration { .milliseconds(250) }

    /// The longest the corridor between the card and the popup keeps it open (a slow hand).
    static var notesCorridorLimit: Duration { .milliseconds(1200) }

    /// The popup's height for a page `contentHeight` tall: capped to
    /// ``popoverMaxHeightFraction`` of the window (the page scrolls past it).
    func notesHeight(for contentHeight: CGFloat) -> CGFloat {
        guard let window else { return contentHeight }
        return min(contentHeight, max(120, floor(window.frame.height * Self.popoverMaxHeightFraction)))
    }

    /// The popup shows (or is opening).
    var notesAreShown: Bool { notesPanel?.isPresented == true }

    func hideNotes() {
        cancelNotesClose()
        notesPanel?.dismiss()
    }

    private func makeNotesPanel(_ highlights: any SidebarSurfaceIsland) -> SidebarUpdateNotesPanel {
        let panel = SidebarUpdateNotesPanel(width: Self.popoverWidth)
        panel.host.onPointerExit = { [weak self] in self?.pointerLeftNotes() }
        panel.host.onPointerEnter = { [weak self] in self?.cancelNotesClose() }
        // The close finished: the highlights page goes back to wait in the card.
        // A close under the pointer (Hide, an action, the app resigning) is noted as it
        // starts, so a move during its animation does not reopen it.
        panel.onDismiss = { [weak self] in
            guard let self, self.isHovered else { return }
            self.notesDismissedWhileHovered = true
        }
        panel.onClosed = { [weak self] in self?.parkHighlights() }
        highlights.onHeightChange = { [weak self, weak panel, weak highlights] in
            guard let self, let panel, let highlights, highlights.contentHeight > 0 else { return }
            panel.resize(height: self.notesHeight(for: highlights.contentHeight))
        }
        return panel
    }

    /// Whether `point` (screen, default the pointer now) is over the popup,
    /// with a small margin for the gap between card and popup.
    func pointerIsOverNotes(_ point: CGPoint? = nil) -> Bool {
        guard let panel = notesPanel, panel.isPresented else { return false }
        return panel.cardFrame.insetBy(dx: -Metrics.space2, dy: -Metrics.space2).contains(point ?? screenPointer())
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
        guard let panel = notesPanel, panel.isPresented, let card = cardScreenFrame else { return false }
        let notes = panel.cardFrame
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
        guard notesAreShown else { return }
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
        notesCloseWaited += Self.notesCloseDelay
        if isHovered && !isHiddenOrHasHiddenAncestor { return }
        if let panel = notesPanel, panel.isPresented, panel.cardFrame.contains(screenPointer()) { return }
        let onTheWay = pointerIsInNotesCorridor() || pointerIsOverCard() || pointerIsOverNotes()
        if onTheWay, notesCloseWaited < Self.notesCorridorLimit { return armNotesClose() }
        notesPanel?.dismiss()
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
