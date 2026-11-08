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
/// A pane in front of the page (a zoom growing over it, a docked column) clips the page
/// (`PaneHostView.setStripClip`), but the overlay host draws above every pane: a card is cut
/// the same way as its page (`CEFClipShape`), so it never floats over the pane in front and
/// shows again in the same frame as the page under it. It takes clicks only where it shows,
/// and leaves while none of it shows.
///
/// The chrome owns the cards and places them over `page` (its page area):
/// bottom center (or bottom left, ``Placement/bottomLeading``, the link
/// status bubble), `inset` above its bottom edge plus each card's `lift`,
/// never wider than the page less the insets. A card shows only while the
/// page is in a window and not hidden (a parked tab keeps its cards for when
/// it shows again). The chrome syncs on layout and window, superview and
/// hidden changes; a move of the window's pages without a resize (a pane
/// swap) and a change of what a pane in front cuts of them (each frame of a
/// zoom) arrive as `browserChildWindowPagesNeedUpdate`.
@MainActor
final class PageFloatingOverlays {
    /// Where a card sits on the page's bottom edge.
    enum Placement {
        /// Centered (the notice pill, the cookie import card).
        case bottomCenter
        /// At the left edge (the link status bubble, as Chrome places it).
        case bottomLeading
    }

    private struct Card {
        let view: NSView
        var lift: CGFloat
        var placement: Placement = .bottomCenter
        /// Never takes a click (the link status bubble).
        var passesThroughClicks = false
        var handle: OverlayHandle?
        /// Fading out: it no longer takes clicks (`release`).
        var isReleased = false
        /// Presented but hidden while its tab does not have the keyboard (the cookie import card's
        /// `waitsForFocus`): it takes no clicks, and shows again in place, with no new present.
        var isWaiting = false
        /// Its size the last time it was presented: where a card taken off under a pane in front
        /// would show, without an Auto Layout pass of it on each frame of the motion.
        var lastSize: CGSize?
        /// Where it takes clicks (its own coordinates) while a pane in front cuts it; nil when whole.
        var mouseRect: NSRect?
    }

    private var cards: [Card] = []
    private weak var page: NSView?
    private var pagesObserver: (any NSObjectProtocol)?
    /// Where `browserChildWindowPagesNeedUpdate` arrives (the default center; a test injects its own).
    private let notifications: NotificationCenter

    init(page: NSView, notifications: NotificationCenter = .default) {
        self.page = page
        self.notifications = notifications
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            if let pagesObserver { notifications.removeObserver(pagesObserver) }
            for card in cards { card.handle?.dismiss() }
        }
    }

    /// The cards, bottom of the stack first (tests, diagnostics, lookups).
    var views: [NSView] { cards.map(\.view) }

    /// Adds `view` (an Auto Layout view sized by its own constraints) above
    /// the page; `lift` raises it over the page's bottom inset.
    /// `placement` puts it at the bottom center or left; a card that
    /// `passesThroughClicks` leaves every click to the page.
    func add(_ view: NSView, lift: CGFloat = 0, placement: Placement = .bottomCenter, passesThroughClicks: Bool = false) {
        guard !cards.contains(where: { $0.view === view }) else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        // A pane in front cuts the card with a mask on its own layer (`cut`): the notice pill and the link status
        // bubble have none of their own.
        view.wantsLayer = true
        cards.append(Card(view: view, lift: lift, placement: placement, passesThroughClicks: passesThroughClicks))
        observePages()
    }

    /// `view`, added passing its clicks through while it is not drawn yet (the cookie import card
    /// waits for its page to measure itself), takes clicks from now on, where it is: presenting it
    /// again moved its page to a new view, which drew a blank frame as it faded in (Leo
    /// 2026-11-08: "the import cookies from google chrome card flickers sometimes").
    func startTakingClicks(_ view: NSView) {
        guard let index = cards.firstIndex(where: { $0.view === view }), cards[index].passesThroughClicks,
              !cards[index].isReleased else { return }
        cards[index].passesThroughClicks = false
        if !cards[index].isWaiting { cards[index].handle?.startTakingMouse() }
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
        if cards.isEmpty, let pagesObserver {
            notifications.removeObserver(pagesObserver)
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
        let shown = Self.shownArea(of: page)
        for index in cards.indices {
            let view = cards[index].view
            // A hidden card waits for its tab (one chrome per pane): off screen, it takes no clicks.
            // So does a card that a pane in front of the page covers whole: the page is cut there too.
            if view.isHidden || !shown.showsAny(of: placedRect(of: cards[index], in: clip)) {
                dismiss(index)
                continue
            }
            // Waiting for its tab's keyboard (focus moved to a terminal or chat beside it): hidden
            // where it is. Each focus flip dismissed and presented it again, and its page drew a
            // blank frame when it came back.
            let waits = (view as? BrowserCookieImportCard)?.waitsForFocus == true
            if waits, cards[index].handle == nil { continue }
            if view.themeScope !== scope { scope.root(view) }
            if let handle = cards[index].handle, !handle.isDismissed, view.window?.parent === window {
                handle.update(paneClip: clip)
            } else {
                dismiss(index)
                // The host shows what it presents at full opacity; a card keeps its own (the cookie
                // import card waits clear until its page measured itself, then fades in).
                let alpha = view.alphaValue
                let handle = WindowOverlayHost.host(for: window).present(
                    view, options: OverlayOptions(kind: .attached, anchor: NSRect(origin: clip.origin, size: .zero),
                                                  passesThroughClicks: cards[index].isReleased || cards[index].passesThroughClicks,
                                                  layer: .pane(clip: clip))
                )
                view.alphaValue = alpha
                cards[index].handle = handle
                cards[index].isWaiting = false
                if let holder = view.superview { pin(view, in: holder, lift: cards[index].lift, placement: cards[index].placement) }
            }
            guard let holder = view.superview, let handle = cards[index].handle else { continue }
            if waits != cards[index].isWaiting {
                cards[index].isWaiting = waits
                handle.setHiddenInPlace(waits)
                if waits { handle.stopTakingMouse() }
                else if !cards[index].isReleased, !cards[index].passesThroughClicks { handle.startTakingMouse() }
            }
            holder.layoutSubtreeIfNeeded()
            let solved = view.frame
            cards[index].lastSize = solved.size
            let anchor = NSRect(x: clip.minX + solved.minX, y: clip.minY + solved.minY, width: solved.width, height: solved.height)
            handle.update(anchor: anchor)
            cut(index, at: anchor, to: shown, handle: handle)
        }
    }

    /// Cuts the card at `frame` (window coordinates) to what its page shows: a mask of the shown
    /// part, as the page's own (`StripClipMaskLayer`), and clicks only there; whole, no mask.
    private func cut(_ index: Int, at frame: NSRect, to shown: ShownArea, handle: OverlayHandle) {
        let view = cards[index].view
        var mouseRect: NSRect?
        if shown.shows(frame) {
            if view.layer?.mask is StripClipMaskLayer { view.layer?.mask = nil }
        } else {
            let visible = view.convert(frame.intersection(shown.visible), from: nil)
            // A hole in the card has no one rect to click in: none while a pane cuts into its middle.
            mouseRect = shown.cutouts.contains { $0.intersects(frame) } ? .zero : visible
            if let layer = view.layer {
                let cutouts = shown.cutouts.map { view.convert($0, from: nil) }
                let mask = (layer.mask as? StripClipMaskLayer) ?? StripClipMaskLayer()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                mask.place(visible, cutouts: cutouts, scale: view.window?.backingScaleFactor ?? 2)
                CATransaction.commit()
                if layer.mask !== mask { layer.mask = mask }
            }
        }
        guard cards[index].mouseRect != mouseRect else { return }
        cards[index].mouseRect = mouseRect
        handle.update(anchor: frame, modalRegion: nil, mouseRect: mouseRect)
    }

    /// What a pane in front leaves of `page`, in window coordinates: the rect its square clips
    /// leave (the column strip's clip, a pane's clip, the window) and the rects cut out of it
    /// (a pane in front covering a middle part), as its page is clipped (`CEFClipShape`).
    nonisolated struct ShownArea {
        var visible: CGRect
        var cutouts: [CGRect]

        /// Whether a card at `rect` shows whole: inside the visible rect, under no cutout.
        func shows(_ rect: CGRect) -> Bool {
            visible.insetBy(dx: -0.5, dy: -0.5).contains(rect)
                && !cutouts.contains { let shared = $0.intersection(rect); return !shared.isNull && shared.width > 0.5 && shared.height > 0.5 }
        }

        /// Whether any of a card at `rect` shows: some of it in the visible rect, not all of that under one cutout.
        func showsAny(of rect: CGRect) -> Bool {
            let part = visible.intersection(rect)
            guard !part.isNull, part.width > 0.5, part.height > 0.5 else { return false }
            return !cutouts.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(part) }
        }
    }

    static func shownArea(of page: NSView) -> ShownArea {
        var visible = page.bounds
        for clip in CEFClipShape.clips(around: page) { visible = visible.intersection(clip.rect) }
        return ShownArea(visible: visible.isNull ? .zero : page.convert(visible, to: nil),
                         cutouts: CEFClipShape.cutouts(around: page).map { page.convert($0, to: nil) })
    }

    /// Where `card` shows in window coordinates over the page area `clip`, at its place
    /// (``pin(_:in:lift:placement:)``): with its solved size while presented, the size it had when
    /// last presented while off, its fitting size only before it ever showed.
    private func placedRect(of card: Card, in clip: CGRect) -> CGRect {
        let inset = BrowserMetrics.overlayInset
        let size = if card.handle != nil, card.view.frame.width > 0 { card.view.frame.size } else { card.lastSize ?? card.view.fittingSize }
        let width = min(size.width, max(0, clip.width - inset * 2))
        let x = switch card.placement {
        case .bottomCenter: clip.midX - width / 2
        case .bottomLeading: clip.minX + inset
        }
        // A card taller than a short page shows cut by it, as before: only what of it the page holds counts.
        return CGRect(x: x, y: clip.minY + inset + card.lift, width: width, height: size.height).intersection(clip)
    }

    /// The card's place in its overlay clip, as it was in the chrome.
    private func pin(_ view: NSView, in holder: NSView, lift: CGFloat, placement: Placement) {
        let inset = BrowserMetrics.overlayInset
        let horizontal = switch placement {
        case .bottomCenter: view.centerXAnchor.constraint(equalTo: holder.centerXAnchor)
        case .bottomLeading: view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: inset)
        }
        NSLayoutConstraint.activate([
            horizontal,
            view.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -inset - lift),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -inset),
        ])
    }

    /// Whether a click at `view`'s center goes to the overlay host
    /// (diagnostics); nil when it is not presented.
    func takesMouse(_ view: NSView) -> Bool? {
        guard let window = view.window?.parent, view.superview != nil,
              let host = WindowOverlayHost.existingHost(for: window) else { return nil }
        let frame = view.convert(view.bounds, to: nil)
        return host.acceptsMouse(at: NSPoint(x: frame.midX, y: frame.midY))
    }

    /// The window's pages moved or were re-clipped without a layout of this
    /// chrome (a pane swap of equal size): the cards follow.
    private func observePages() {
        guard pagesObserver == nil else { return }
        pagesObserver = notifications.addObserver(
            forName: Notification.Name.browserChildWindowPagesNeedUpdate, object: nil, queue: .main
        ) { [weak self] note in
            // Only the window's identity crosses into the main-actor closure.
            let window = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                guard let self, let window, window == self.page?.window.map(ObjectIdentifier.init) else { return }
                self.sync()
            }
        }
    }

    private func dismiss(_ index: Int) {
        let handle = cards[index].handle
        cards[index].handle = nil
        cards[index].isWaiting = false
        cards[index].mouseRect = nil
        handle?.dismiss()
    }
}
