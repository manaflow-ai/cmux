/// The Chromium side of one ``PageWebView`` in Chromium mode: the page, its bridge and the
/// deadline by which the page must reach the host (else the view falls back to WebKit).
import CmuxNextWakeups

@MainActor
final class PageChromiumSession {
    let page: any PageChromiumPage
    let bridge: ChromiumPageHostBridge
    /// Cancelled when the page reaches the host or the session ends.
    let deadline: DemandTimer
    /// Agent question keyboard proof, separate from the page's general main-world bridge.
    var questionKeys: ChromiumQuestionKeyChannel?

    init(page: any PageChromiumPage, bridge: ChromiumPageHostBridge, clock: any Clock<Duration>) {
        self.page = page
        self.bridge = bridge
        deadline = DemandTimer(owner: "page.chromium.deadline", clock: clock)
    }

    /// Stops the bridge and closes the page. Idempotent.
    func end() {
        questionKeys?.invalidate()
        deadline.cancel()
        bridge.uninstall()
        page.onEvent = nil
        page.resources = nil
        page.contentView.removeFromSuperview()
        page.close()
    }
}
