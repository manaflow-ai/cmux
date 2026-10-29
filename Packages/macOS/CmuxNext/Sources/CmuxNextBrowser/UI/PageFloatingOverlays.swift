import AppKit
import CmuxNextCompat
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
/// The chrome owns the cards and places them over `page` (its page area) by
/// frame (`PageCardPlacement`): bottom center, `inset` above its bottom edge
/// plus each card's `lift`, never wider than the page less the insets; a
/// `PageFloatingCard` says its size for that width, any other card takes its
/// fitting size. Chrome sizes a bubble the same way, from its contents'
/// preferred size (ui/views/bubble/bubble_dialog_delegate.cc,
/// `SizeToContents()`). A card shows only while the
/// page is in a window and not hidden (a parked tab keeps its cards for when
/// it shows again). The chrome syncs on layout and window, superview and
/// hidden changes; a move of the window's pages without a resize (a pane
/// swap) arrives as the window's page update request
/// (`ChildPageGeometryRegistry`): only the page's own window's requests reach the cards.
@MainActor
final class PageFloatingOverlays {
    private struct Card {
        let view: NSView
        var lift: CGFloat
        var handle: OverlayHandle?
        /// Fading out: it no longer takes clicks (`release`).
        var isReleased = false
    }

    private var cards: [Card] = []
    private weak var page: NSView?
    /// The cards' place in the page's window's `ChildPageGeometryRegistry`, while they have cards there.
    private var pageUpdates: (registry: ChildPageGeometryRegistry, registration: ChildPageGeometryRegistry.Registration)?

    init(page: NSView) {
        self.page = page
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            for card in cards { card.handle?.dismiss() }
        }
    }

    /// The cards, bottom of the stack first (tests, diagnostics, lookups).
    var views: [NSView] { cards.map(\.view) }

    /// Adds `view` above the page; `lift` raises it over the page's bottom
    /// inset. The card is placed by frame, also one built with constraints
    /// inside (they size its content, never its place).
    func add(_ view: NSView, lift: CGFloat = 0) {
        guard !cards.contains(where: { $0.view === view }) else { return }
        view.translatesAutoresizingMaskIntoConstraints = true
        cards.append(Card(view: view, lift: lift))
        followPages(of: page?.window)
    }

    /// `view` starts to fade out: from now on clicks pass through it to the
    /// page, also when it is presented again before the fade ends.
    func release(_ view: NSView) {
        guard let index = cards.firstIndex(where: { $0.view === view }) else { return }
        cards[index].isReleased = true
        cards[index].handle?.stopTakingMouse()
    }

    /// Takes `view` off the page (its overlay goes away at once).
    func remove(_ view: NSView) {
        guard let index = cards.firstIndex(where: { $0.view === view }) else { return }
        cards.remove(at: index).handle?.dismiss()
        if cards.isEmpty { pageUpdates = nil }
    }

    /// Places every card over the page when it shows in a window, else
    /// takes them off screen until it does. Inside its overlay clip (the
    /// page area) a card goes where `PageCardPlacement` puts it; the host
    /// gets that frame as the card's anchor, so its mouse regions match the
    /// card.
    func sync() {
        guard !cards.isEmpty, let page else { return }
        followPages(of: page.window)
        // visibility-walk-allow: the cards are child windows placed over the page AppKit shows; a node would place them a turn after the page
        guard let window = page.window, !page.isHiddenOrHasHiddenAncestor else {
            for index in cards.indices { dismiss(index) }
            return
        }
        let clip = page.convert(page.bounds, to: nil)
        let scope = page.themeScope
        let placement = PageCardPlacement(inset: BrowserMetrics.overlayInset)
        for index in cards.indices {
            let view = cards[index].view
            if view.themeScope !== scope { scope.root(view) }
            let frame = placement.frame(for: Self.size(of: view, maxWidth: placement.maxWidth(in: clip.size)),
                                        lift: cards[index].lift, in: clip.size)
            if view.frame.size != frame.size { view.setFrameSize(frame.size) }
            if let handle = cards[index].handle, !handle.isDismissed, view.window?.parent === window {
                handle.update(paneClip: clip)
            } else {
                dismiss(index)
                cards[index].handle = WindowOverlayHost.host(for: window).present(
                    view, options: OverlayOptions(kind: .attached, anchor: NSRect(origin: clip.origin, size: .zero),
                                                  passesThroughClicks: cards[index].isReleased, layer: .pane(clip: clip))
                )
            }
            cards[index].handle?.update(anchor: frame.offsetBy(dx: clip.minX, dy: clip.minY))
        }
    }

    /// A card's size at most `maxWidth` wide.
    private static func size(of view: NSView, maxWidth: CGFloat) -> CGSize {
        if let card = view as? any PageFloatingCard { return card.cardSize(maxWidth: maxWidth) }
        let fitting = view.fittingSize
        return CGSize(width: min(fitting.width, maxWidth), height: fitting.height)
    }

    /// Whether a click at `view`'s center goes to the overlay host
    /// (diagnostics); nil when it is not presented.
    func takesMouse(_ view: NSView) -> Bool? {
        guard let window = view.window?.parent, view.superview != nil,
              let host = WindowOverlayHost.existingHost(for: window) else { return nil }
        let frame = view.convert(view.bounds, to: nil)
        return host.acceptsMouse(at: NSPoint(x: frame.midX, y: frame.midY))
    }

    /// The page's window's pages moved or were re-clipped without a layout of
    /// this chrome (a pane swap of equal size): the cards follow. Only that
    /// window's page updates reach them; a page that changed window takes its
    /// cards to the new window's registry on the next sync.
    private func followPages(of window: NSWindow?) {
        guard let window else {
            pageUpdates = nil
            return
        }
        let registry = ChildPageGeometryRegistry.of(window)
        guard pageUpdates?.registry !== registry else { return }
        // Cards are not pages: they report no page change.
        let registration = registry.register { [weak self] _ in
            self?.sync()
            return false
        }
        pageUpdates = (registry, registration)
    }

    private func dismiss(_ index: Int) {
        let handle = cards[index].handle
        cards[index].handle = nil
        handle?.dismiss()
    }
}

/// A floating card that sizes itself for the page: its frame size when it
/// may be at most `maxWidth` wide.
@MainActor
protocol PageFloatingCard: NSView {
    func cardSize(maxWidth: CGFloat) -> CGSize
}

/// Where a floating card goes in its page: bottom center, `inset` above the
/// bottom edge plus its lift, at most the page less the side insets wide.
nonisolated struct PageCardPlacement: Equatable, Sendable {
    var inset: CGFloat

    /// The widest a card may be in a page of `page` size.
    func maxWidth(in page: CGSize) -> CGFloat { max(page.width - inset * 2, 0) }

    /// The card's frame in the page (the page's bottom left at the origin).
    func frame(for size: CGSize, lift: CGFloat, in page: CGSize) -> CGRect {
        let width = min(size.width, maxWidth(in: page))
        return CGRect(x: ((page.width - width) / 2).rounded(.down), y: inset + lift, width: width, height: size.height)
    }
}
