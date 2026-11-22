import AppKit
import CmuxNextDesign

// UPDATE-CARD: the release notes popover opens while the pointer is over
// the card (or its button) and stays while the pointer moves into it, so
// its links can be clicked. No timers: each exit checks where the pointer
// is now. The notes were fetched with the update, so opening it reads no
// network.
extension SidebarUpdateCardView {
    /// Opens the popover beside the card (toward the content, away from
    /// the window edge). No-op without a card or a window. A popover that
    /// is still closing (the pointer left and came back) opens again.
    func showNotes() {
        guard card != nil, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let popover = popover ?? makePopover()
        self.popover = popover
        popover.appearance = effectiveAppearance
        notesView.applyColors()
        notesView.layoutSubtreeIfNeeded()
        // The content's own size: a zero first size would show nothing.
        popover.contentSize = notesView.fittingSize
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
    }

    func hideNotes() {
        guard let popover, popover.isShown else { return }
        popover.performClose(nil)
    }

    /// Whether the popover is on screen.
    var isShowingNotes: Bool { popover?.isShown == true }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = Motion.animatesMovement
        let controller = NSViewController()
        controller.view = notesView
        popover.contentViewController = controller
        return popover
    }

    /// Whether the pointer is over the popover's window now (with a small
    /// margin for the gap between card and popover).
    func pointerIsOverNotes() -> Bool {
        guard let window = popover?.contentViewController?.view.window, popover?.isShown == true else { return false }
        return window.frame.insetBy(dx: -Metrics.space2, dy: -Metrics.space2).contains(NSEvent.mouseLocation)
    }

    /// Whether the pointer is over the card now.
    private func pointerIsOverCard() -> Bool {
        guard let window else { return false }
        let card = window.convertToScreen(convert(bounds, to: nil))
        return card.insetBy(dx: -Metrics.space1, dy: -Metrics.space1).contains(NSEvent.mouseLocation)
    }

    /// The pointer left the popover: it closes unless the pointer is back
    /// on the card.
    func pointerLeftNotes() {
        guard !pointerIsOverCard() else { return }
        hideNotes()
    }
}
