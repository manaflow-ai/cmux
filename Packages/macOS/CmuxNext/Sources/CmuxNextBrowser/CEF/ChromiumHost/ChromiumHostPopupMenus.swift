import AppKit
import CmuxNextCompat

/// Where cmux answers the host's popups: the host's wire in the app, a recorder in tests.
protocol ChromiumHostPopupMenuWire: AnyObject {
    /// Answers `browser`'s popup `token` once: `index` is the chosen item, -1 for none.
    func reply(browser: Int32, token: Int64, index: Int32)
}

/// Shows the Chromium Host's `<select>` popups as cmux menus (host mode, feature
/// `chromiumHostPopupMenus`). One popup at a time, as AppKit tracks one menu: POPUP_MENU shows it
/// over its page view on the next run loop turn (``show(browser:token:popup:)``; the event comes
/// inside the runtime's event dispatch, where a menu's tracking loop would hold every later event),
/// and the person's choice or dismissal is the answer. POPUP_MENU_HIDE closes it with no answer
/// (``hide(browser:token:)``), as do the page's close and the host's end. Every popup the host sent
/// gets exactly one answer unless Chromium took it back first, so a page never waits on a menu
/// that is not there.
final class ChromiumHostPopupMenus {
    /// How the menus run; tests track without a window server.
    struct Seams {
        /// Runs the body on a later main run loop pass, also during another menu's tracking.
        var later: @MainActor (@escaping @MainActor () -> Void) -> Void = { MainRunLoopBlock($0).perform() }
        /// Tracks the menu until it closes and returns the chosen item's index, nil for none.
        var track: @MainActor (ChromiumHostPopupMenuRun) -> Int? = { $0.track() }
    }

    /// The popup that is showing or about to.
    private struct Open {
        var browser: Int32
        var token: Int64
        /// Set while the menu tracks.
        var menu: NSMenu?
        /// Chromium took it back, its page closed or the host ended: it gets no answer.
        var cancelled = false
    }

    private let wire: any ChromiumHostPopupMenuWire
    /// The view that shows `browser`'s page now, nil when no pane shows it.
    private let pageView: @MainActor (Int32) -> NSView?
    private let seams: Seams
    private var open: Open?

    init(wire: any ChromiumHostPopupMenuWire, pageView: @escaping @MainActor (Int32) -> NSView?, seams: Seams = Seams()) {
        self.wire = wire
        self.pageView = pageView
        self.seams = seams
    }

    /// The menu while it tracks (`debug.menu`).
    var presentedMenu: NSMenu? { open?.menu }

    /// POPUP_MENU: shows `popup` over `browser`'s page on the next run loop turn. A popup this cmux
    /// cannot read (nil), or one of a page no pane shows, is answered -1 at once.
    func show(browser: Int32, token: Int64, popup: ChromiumHostPopupMenu?) {
        if let current = open { end(current, answer: -1) }
        guard let popup, pageView(browser)?.window != nil else { return wire.reply(browser: browser, token: token, index: -1) }
        open = Open(browser: browser, token: token)
        seams.later { [weak self] in self?.run(popup, browser: browser, token: token) }
    }

    /// POPUP_MENU_HIDE: Chromium closed `browser`'s popup `token` first; its menu closes with no answer.
    func hide(browser: Int32, token: Int64) {
        guard let current = open, current.browser == browser, current.token == token else { return }
        cancel(current)
    }

    /// The page closed (BEFORE_CLOSE): its popup went with it.
    func ownerClosed(_ browser: Int32) {
        guard let current = open, current.browser == browser else { return }
        cancel(current)
    }

    /// The host ended: its popups went with it, and nothing can be answered.
    func hostEnded() {
        guard let current = open else { return }
        cancel(current)
    }

    private func run(_ popup: ChromiumHostPopupMenu, browser: Int32, token: Int64) {
        guard let current = open, current.token == token, current.browser == browser else { return }
        // The page left its pane or window between the event and this turn.
        guard let view = pageView(browser), view.window != nil else { return end(current, answer: -1) }
        let menuRun = ChromiumHostPopupMenuRun(popup, in: view)
        open?.menu = menuRun.menu
        let chosen = seams.track(menuRun)
        // A popup that came during tracking has already ended this one.
        guard let after = open, after.token == token, after.browser == browser else { return }
        open = nil
        guard !after.cancelled else { return }
        let index = chosen.flatMap { popup.items.indices.contains($0) && popup.items[$0].isChoosable ? $0 : nil } ?? -1
        wire.reply(browser: browser, token: token, index: Int32(index))
    }

    /// Answers `current` and forgets it; a tracking menu closes.
    private func end(_ current: Open, answer: Int32) {
        open = nil
        current.menu?.cancelTrackingWithoutAnimation()
        if !current.cancelled { wire.reply(browser: current.browser, token: current.token, index: answer) }
    }

    /// Forgets `current` with no answer. A tracking menu closes, and its run sends nothing.
    private func cancel(_ current: Open) {
        guard let menu = current.menu else {
            open = nil
            return
        }
        open?.cancelled = true
        menu.cancelTrackingWithoutAnimation()
    }
}
