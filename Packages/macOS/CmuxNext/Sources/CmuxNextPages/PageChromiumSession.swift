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
    /// Freezes the page while it stays hidden: the policy of the host that made the page
    /// (``PageChromiumHosting/freezePolicy``).
    let freezePolicy: any PageFreezePolicy
    /// Whether Chromium draws the page now, as this session last set it (``setShown(_:)``, and the
    /// hide of a ``freeze()``); nil before the first.
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
        freezePolicy = hosting.freezePolicy
        deadline = DemandTimer(owner: "page.chromium.deadline", clock: clock)
    }

    /// Whether nobody can see the page now: hidden, parked, out of a window, or its window covered,
    /// minimized or ordered out.
    var isHidden: Bool { seen == false }

    /// Shows or hides the page (Chromium stops drawing a hidden page). Only a change is sent, and
    /// nothing while the page is frozen: a frozen page stays hidden, and ``thaw(shown:)`` sets the
    /// visibility the view needs then.
    func setShown(_ shown: Bool) {
        guard !frozen, shown != self.shown else { return }
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

    /// Hides and freezes the page (``PageChromiumPage/setFrozen(_:)``); the caller checked that it
    /// may. Chromium hides a page it freezes (its lifecycle handler hides the WebContents first) and
    /// shows it again only on a show, never on the thaw: so the session hides it itself, and
    /// ``shown`` stays what Chromium does. A page frozen while it still draws (its window covered,
    /// minimized or ordered out) then gets its show at the thaw.
    func freeze() {
        setShown(false)
        frozen = true
        page.setFrozen(true)
    }

    /// Thaws a frozen page, then shows it again when the view shows (`shown`); nothing for a live
    /// page.
    ///
    /// - Parameter shown: Whether the view shows now (``PageWebView/isShownForChromium``).
    /// - Returns: True when the page was frozen.
    func thaw(shown: Bool) -> Bool {
        guard frozen else { return false }
        frozen = false
        page.setFrozen(false)
        setShown(shown)
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
