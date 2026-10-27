/// The Chromium side of one ``PageWebView`` in Chromium mode: the page, its bridge and the
/// deadline by which the page must reach the host (else the view falls back to WebKit).
import CmuxNextWakeups

@MainActor
final class PageChromiumSession {
    let page: any PageChromiumPage
    let bridge: ChromiumPageHostBridge
    /// The app's lanes (``PageChromiumHosting/work``): the page's large replies are decoded on them.
    let work: BackgroundWork
    /// Cancelled when the page reaches the host or the session ends.
    let deadline: DemandTimer
    /// The page's "Page unresponsive" card (``PageChromiumEvent/unresponsive``).
    let hang: PageHangNotice

    init(page: any PageChromiumPage, bridge: ChromiumPageHostBridge, work: BackgroundWork, clock: any Clock<Duration>,
         hang: PageHangNotice) {
        self.page = page
        self.bridge = bridge
        self.work = work
        self.hang = hang
        deadline = DemandTimer(owner: "page.chromium.deadline", clock: clock)
    }

    /// Stops the bridge, takes the hang card down and closes the page. Idempotent.
    func end() {
        deadline.cancel()
        hang.end()
        bridge.uninstall()
        page.onEvent = nil
        page.resources = nil
        page.contentView.removeFromSuperview()
        page.close()
    }
}
