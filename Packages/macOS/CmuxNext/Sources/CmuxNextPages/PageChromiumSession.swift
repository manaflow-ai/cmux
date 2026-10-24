/// The Chromium side of one ``PageWebView`` in Chromium mode: the page, its bridge, the deadline by
/// which the page must reach the host (else the view falls back to WebKit), whether the page shows
/// and is seen, and whether the hibernation froze it (PageWebView+ChromiumCost.swift).
import CmuxNextWakeups

@MainActor
final class PageChromiumSession {
    let page: any PageChromiumPage
    let bridge: ChromiumPageHostBridge
    /// Cancelled when the page reaches the host or the session ends.
    let deadline: DemandTimer
    /// The host that made the page; its ``PageChromiumHosting/freezePolicy`` is read at each report,
    /// so a page that started before the app's hibernation did still freezes.
    private let hosting: any PageChromiumHosting
    /// Freezes the page while it stays hidden; nil never freezes.
    var freezePolicy: (any PageFreezePolicy)? { hosting.freezePolicy }
    /// The last ``setShown(_:)`` (Chromium draws the page); nil before the first.
    private(set) var shown: Bool?
    /// The last ``setSeen(_:)`` (shown, in a window on screen); nil before the first.
    private(set) var seen: Bool?
    /// The page is frozen now (``freeze()``); it thaws before it is seen or the host reaches in.
    private(set) var frozen = false
    /// The document said it finished its start (the router's `booted`): only then may it freeze.
    var booted = false
    /// Page messages the host is handling now (a call, a subscribe, until its reply went): the page
    /// waits on them, so it must not freeze.
    var handlingMessages = 0
    /// A theme, scale, attribute or glass script was skipped while frozen: the thaw sends the
    /// document's state again.
    var stateStale = false

    init(page: any PageChromiumPage, bridge: ChromiumPageHostBridge, clock: any Clock<Duration>,
         hosting: any PageChromiumHosting) {
        self.page = page
        self.bridge = bridge
        self.hosting = hosting
        deadline = DemandTimer(owner: "page.chromium.deadline", clock: clock)
    }

    /// Whether nobody can see the page now: hidden, parked, out of a window, or its window covered,
    /// minimized or ordered out.
    var isHidden: Bool { seen == false }

    /// Shows or hides the page (Chromium stops drawing a hidden page). Only a change is sent.
    func setShown(_ shown: Bool) {
        guard shown != self.shown else { return }
        self.shown = shown
        page.setVisible(shown)
    }

    /// Records whether anybody can see the page.
    ///
    /// - Returns: True when that changed.
    func setSeen(_ seen: Bool) -> Bool {
        guard seen != self.seen else { return false }
        self.seen = seen
        return true
    }

    /// Freezes the page (``PageChromiumPage/setFrozen(_:)``); the caller checked that it may.
    func freeze() {
        frozen = true
        page.setFrozen(true)
    }

    /// Thaws a frozen page; nothing for a live one.
    ///
    /// - Returns: True when the page was frozen.
    func thaw() -> Bool {
        guard frozen else { return false }
        frozen = false
        page.setFrozen(false)
        return true
    }

    /// Stops the bridge and closes the page. Idempotent.
    func end() {
        deadline.cancel()
        bridge.uninstall()
        page.onEvent = nil
        page.resources = nil
        page.contentView.removeFromSuperview()
        page.close()
    }
}
