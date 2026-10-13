import AppKit
import CmuxNextDesign

// UPDATE-CARD: the highlights popover (the React ready surface,
// cx-urd.61.2) opens while the pointer is over the card (or its button) and
// stays while the pointer moves into it, so "See all changes" can be
// clicked. No timers: each exit checks where the pointer is now. The
// highlights were read when the update staged, so opening it reads no
// network.
extension SidebarUpdateCardView {
    /// Opens the popover beside the card (toward the content, away from
    /// the window edge). No-op without a card or a window. A popover that
    /// is still closing (the pointer left and came back) opens again.
    func showNotes() {
        guard card != nil, let highlights, highlights.contentHeight > 0, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let popover = popover ?? makePopover(highlights)
        self.popover = popover
        (popover.contentViewController?.view as? SidebarPopoverIslandHost)?.adopt(highlights)
        popover.appearance = effectiveAppearance
        popover.contentViewController?.view.fillWithPopupSurface(themeOf: self)
        // The page's own height: a zero first size would show nothing.
        popover.contentSize = NSSize(width: Self.popoverWidth, height: highlights.contentHeight)
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
    }

    static var popoverWidth: CGFloat { 300 }

    func hideNotes() {
        guard let popover, popover.isShown else { return }
        popover.performClose(nil)
    }

    private func makePopover(_ highlights: any SidebarSurfaceIsland) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = Motion.animatesMovement
        let host = SidebarPopoverIslandHost(width: Self.popoverWidth)
        host.onPointerExit = { [weak self] in self?.pointerLeftNotes() }
        highlights.onHeightChange = { [weak popover, weak highlights] in
            guard let popover, let highlights, highlights.contentHeight > 0, popover.isShown else { return }
            popover.contentSize = NSSize(width: Self.popoverWidth, height: highlights.contentHeight)
        }
        popover.delegate = self
        let controller = NSViewController()
        controller.view = host
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

extension SidebarUpdateCardView: NSPopoverDelegate {
    /// The popover closed: the highlights page goes back to wait in the card.
    func popoverDidClose(_ notification: Notification) {
        // A close that arrives after the popover showed again keeps the page.
        guard popover?.isShown != true else { return }
        parkHighlights()
    }
}
