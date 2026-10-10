import AppKit
import CmuxNextDesign

/// The cards that float over the bottom of a browser page (the notice pill,
/// the cookie import card), for both engines.
///
/// A Chromium page is a child window above the main window's own views, so
/// a card in the chrome's view tree is under the page (cx-whr7: the "This
/// tab runs on this Mac" pill was on no screen and in no capture). The cards
/// draw on the window's overlay host instead, in the `.pane` layer clipped
/// to the page area (plans/cmux-next/overlay-host.md): above every page
/// window, below the sidebar, and real glass over the live page. A WebKit
/// page uses the same path, so both engines show one card the same way.
///
/// The chrome owns the cards and places them: bottom center of the page,
/// `inset` above its bottom edge plus each card's `lift`, never wider than
/// the page less the insets. A card shows only while the chrome is in a
/// window and not hidden (a parked tab keeps its cards for when it shows
/// again).
@MainActor
final class PageFloatingOverlays {
    private struct Card {
        let view: NSView
        var lift: CGFloat
        let maxWidth: NSLayoutConstraint
        var handle: OverlayHandle?
    }

    private var cards: [Card] = []

    /// The cards, bottom of the stack first (tests, diagnostics, lookups).
    var views: [NSView] { cards.map(\.view) }

    /// Adds `view` (an Auto Layout view sized by its own constraints) above
    /// the page; `lift` raises it over the page's bottom inset.
    func add(_ view: NSView, lift: CGFloat = 0) {
        guard !cards.contains(where: { $0.view === view }) else { return }
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        let maxWidth = view.widthAnchor.constraint(lessThanOrEqualToConstant: 10_000)
        maxWidth.isActive = true
        cards.append(Card(view: view, lift: lift, maxWidth: maxWidth))
    }

    /// Takes `view` off the page (its overlay goes away at once).
    func remove(_ view: NSView) {
        guard let index = cards.firstIndex(where: { $0.view === view }) else { return }
        let card = cards.remove(at: index)
        card.maxWidth.isActive = false
        card.handle?.dismiss()
    }

    /// Places every card over `page` (the chrome's page area) when `page`
    /// shows in a window, else takes them off screen until it does.
    func sync(over page: NSView) {
        guard !cards.isEmpty else { return }
        guard let window = page.window, !page.isHiddenOrHasHiddenAncestor else {
            for index in cards.indices { dismiss(index) }
            return
        }
        let clip = page.convert(page.bounds, to: nil)
        let inset = BrowserMetrics.overlayInset
        let scope = page.themeScope
        for index in cards.indices {
            let view = cards[index].view
            cards[index].maxWidth.constant = max(0, clip.width - 2 * inset)
            let size = Self.fittingSize(of: view)
            if view.frame.size != size { view.setFrameSize(size) }
            let origin = NSRect(x: clip.midX - size.width / 2, y: clip.minY + inset + cards[index].lift,
                                width: size.width, height: size.height)
            if let handle = cards[index].handle, !handle.isDismissed, view.window?.parent === window {
                handle.update(paneClip: clip)
                handle.update(anchor: origin)
                continue
            }
            dismiss(index)
            scope.root(view)
            let handle = WindowOverlayHost.host(for: window).present(
                view, options: OverlayOptions(kind: .attached, anchor: origin, layer: .pane(clip: clip))
            )
            cards[index].handle = handle
        }
    }

    /// The size `view`'s own constraints ask for. Measured with its
    /// autoresizing constraints off: they pin the current frame, so a card
    /// first sized empty (before its text) would keep that size.
    private static func fittingSize(of view: NSView) -> NSSize {
        view.translatesAutoresizingMaskIntoConstraints = false
        defer { view.translatesAutoresizingMaskIntoConstraints = true }
        return view.fittingSize
    }

    private func dismiss(_ index: Int) {
        let handle = cards[index].handle
        cards[index].handle = nil
        handle?.dismiss()
    }
}
