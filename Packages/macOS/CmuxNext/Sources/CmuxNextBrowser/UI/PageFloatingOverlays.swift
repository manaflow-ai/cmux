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
/// The chrome owns the cards and places them over `page` (its page area):
/// bottom center, `inset` above its bottom edge plus each card's `lift`,
/// never wider than the page less the insets. A card shows only while the
/// page is in a window and not hidden (a parked tab keeps its cards for when
/// it shows again). The chrome syncs on layout and window, superview and
/// hidden changes; a move of the window's pages without a resize (a pane
/// swap) arrives as `browserChildWindowPagesNeedUpdate`.
@MainActor
final class PageFloatingOverlays {
    private struct Card {
        let view: NSView
        var lift: CGFloat
        var handle: OverlayHandle?
    }

    private var cards: [Card] = []
    private weak var page: NSView?
    private var pagesObserver: (any NSObjectProtocol)?

    init(page: NSView) {
        self.page = page
    }

    isolated deinit {
        if let pagesObserver { NotificationCenter.default.removeObserver(pagesObserver) }
        for card in cards { card.handle?.dismiss() }
    }

    /// The cards, bottom of the stack first (tests, diagnostics, lookups).
    var views: [NSView] { cards.map(\.view) }

    /// Adds `view` (an Auto Layout view sized by its own constraints) above
    /// the page; `lift` raises it over the page's bottom inset.
    func add(_ view: NSView, lift: CGFloat = 0) {
        guard !cards.contains(where: { $0.view === view }) else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        cards.append(Card(view: view, lift: lift))
        observePages()
    }

    /// Takes `view` off the page (its overlay goes away at once).
    func remove(_ view: NSView) {
        guard let index = cards.firstIndex(where: { $0.view === view }) else { return }
        cards.remove(at: index).handle?.dismiss()
        if cards.isEmpty, let pagesObserver {
            NotificationCenter.default.removeObserver(pagesObserver)
            self.pagesObserver = nil
        }
    }

    /// Places every card over the page when it shows in a window, else
    /// takes them off screen until it does. Inside its overlay clip (the
    /// page area) a card keeps the constraints it had in the chrome: bottom
    /// center, at least `inset` from the sides, its width from its own
    /// content. The host then gets the frame Auto Layout solved, so its
    /// mouse regions match the card.
    func sync() {
        guard !cards.isEmpty, let page else { return }
        guard let window = page.window, !page.isHiddenOrHasHiddenAncestor else {
            for index in cards.indices { dismiss(index) }
            return
        }
        let clip = page.convert(page.bounds, to: nil)
        let scope = page.themeScope
        for index in cards.indices {
            let view = cards[index].view
            if view.themeScope !== scope { scope.root(view) }
            if let handle = cards[index].handle, !handle.isDismissed, view.window?.parent === window {
                handle.update(paneClip: clip)
            } else {
                dismiss(index)
                let handle = WindowOverlayHost.host(for: window).present(
                    view, options: OverlayOptions(kind: .attached, anchor: NSRect(origin: clip.origin, size: .zero), layer: .pane(clip: clip))
                )
                cards[index].handle = handle
                if let holder = view.superview { pin(view, in: holder, lift: cards[index].lift) }
            }
            guard let holder = view.superview, let handle = cards[index].handle else { continue }
            holder.layoutSubtreeIfNeeded()
            let solved = view.frame
            handle.update(anchor: NSRect(x: clip.minX + solved.minX, y: clip.minY + solved.minY,
                                         width: solved.width, height: solved.height))
        }
    }

    /// The card's place in its overlay clip, as it was in the chrome.
    private func pin(_ view: NSView, in holder: NSView, lift: CGFloat) {
        let inset = BrowserMetrics.overlayInset
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            view.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -inset - lift),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor, constant: inset),
        ])
    }

    /// The window's pages moved or were re-clipped without a layout of this
    /// chrome (a pane swap of equal size): the cards follow.
    private func observePages() {
        guard pagesObserver == nil else { return }
        pagesObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.browserChildWindowPagesNeedUpdate, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                guard let self, let window = note.object as? NSWindow, window === self.page?.window else { return }
                self.sync()
            }
        }
    }

    private func dismiss(_ index: Int) {
        let handle = cards[index].handle
        cards[index].handle = nil
        handle?.dismiss()
    }
}
