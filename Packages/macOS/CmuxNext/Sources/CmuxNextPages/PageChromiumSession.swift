/// The Chromium side of one ``PageWebView`` in Chromium mode: the page, its bridge, the deadline by
/// which the page must reach the host (else the view falls back to WebKit), and whether the page
/// shows and whether the hibernation froze it.
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
    /// The last ``show(_:)``; nil before the first.
    private(set) var shown: Bool?
    /// The page is frozen now (``freeze()``); it thaws before it shows or the host calls it.
    private(set) var frozen = false
    /// The page's first message reached the host: it booted, so a freeze no longer stops its start.
    var reachedHost = false

    init(page: any PageChromiumPage, bridge: ChromiumPageHostBridge, clock: any Clock<Duration>,
         hosting: any PageChromiumHosting) {
        self.page = page
        self.bridge = bridge
        self.hosting = hosting
        deadline = DemandTimer(owner: "page.chromium.deadline", clock: clock)
    }

    /// Whether the page is hidden now.
    var isHidden: Bool { shown == false }

    /// Shows or hides the page (Chromium stops drawing a hidden page); a frozen page thaws before
    /// it shows. Only a change is sent.
    ///
    /// - Returns: True when the visibility changed.
    @discardableResult
    func show(_ shown: Bool) -> Bool {
        if shown { thaw() }
        guard shown != self.shown else { return false }
        self.shown = shown
        page.setVisible(shown)
        return true
    }

    /// Freezes the page when it is hidden and booted (its first message reached the host), so a
    /// page that hid while it started still finishes its start. The hibernation's grace decides
    /// when (``PageFreezePolicy``), never a hide by itself.
    ///
    /// - Returns: True when the page froze now.
    func freeze() -> Bool {
        guard isHidden, reachedHost, !frozen else { return false }
        frozen = true
        page.setFrozen(true)
        return true
    }

    /// Thaws a frozen page; nothing for a live one.
    ///
    /// - Returns: True when the page was frozen.
    @discardableResult
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
