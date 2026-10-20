import AppKit
import CmuxNextDesign

// UPDATE-CARD: the highlights popup (the React ready surface, cx-urd.61.2,
// in the themed popup of SidebarUpdateNotesPanel) opens while the pointer is
// over the card (or its button) and stays while the pointer moves into it,
// so "See all changes" can be clicked. No timers: each exit checks where the
// pointer is now. The highlights were read when the update staged, so
// opening it reads no network.
extension SidebarUpdateCardView {
    /// Opens the popup beside the card (toward the content, away from the
    /// window edge). No-op without a card or a window. A popup that is still
    /// closing (the pointer left and came back) opens again.
    func showNotes() {
        guard card != nil, let highlights, highlights.contentHeight > 0, let window, !isHiddenOrHasHiddenAncestor else { return }
        let panel = notesPanel ?? makeNotesPanel(highlights)
        notesPanel = panel
        panel.host.adopt(highlights)
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        panel.present(beside: anchor, height: highlights.contentHeight, parent: window, themeAnchor: self)
    }

    static var popoverWidth: CGFloat { 300 }

    /// The popup shows (or is opening).
    var notesAreShown: Bool { notesPanel?.isPresented == true }

    func hideNotes() {
        notesPanel?.dismiss()
    }

    private func makeNotesPanel(_ highlights: any SidebarSurfaceIsland) -> SidebarUpdateNotesPanel {
        let panel = SidebarUpdateNotesPanel(width: Self.popoverWidth)
        panel.host.onPointerExit = { [weak self] in self?.pointerLeftNotes() }
        // The close finished: the highlights page goes back to wait in the card.
        panel.onClosed = { [weak self] in self?.parkHighlights() }
        highlights.onHeightChange = { [weak panel, weak highlights] in
            guard let panel, let highlights, highlights.contentHeight > 0 else { return }
            panel.resize(height: highlights.contentHeight)
        }
        return panel
    }

    /// Whether the pointer is over the popup now (with a small margin for
    /// the gap between card and popup).
    func pointerIsOverNotes() -> Bool {
        guard let panel = notesPanel, panel.isPresented else { return false }
        return panel.cardFrame.insetBy(dx: -Metrics.space2, dy: -Metrics.space2).contains(screenPointer())
    }

    /// Whether the pointer is over the card now.
    func pointerIsOverCard() -> Bool {
        guard let window else { return false }
        let card = window.convertToScreen(convert(bounds, to: nil))
        return card.insetBy(dx: -Metrics.space1, dy: -Metrics.space1).contains(screenPointer())
    }

    /// The pointer left the popup: it closes unless the pointer is back
    /// on the card.
    func pointerLeftNotes() {
        guard !pointerIsOverCard() else { return }
        hideNotes()
    }
}
