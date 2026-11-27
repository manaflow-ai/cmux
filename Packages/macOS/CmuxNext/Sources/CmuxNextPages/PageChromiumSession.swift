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
    /// Follows the renderer's hang state for app health (PageWebView+Chromium).
    var hangWatch: Task<Void, Never>?
    /// Restarts this page's renderer when it stays hung (agent chats only; ``AgentRendererHangRestart``).
    var hangRestart: AgentRendererHangRestart?
    /// What the page view told ``page`` last: it shows. ``setVisible(_:)`` is its only writer.
    private(set) var shows = false
    /// The page view told ``page`` it is hidden last (false until it told it anything): its document is hidden then and
    /// sends no heartbeat, so app health must not time it (``PageWebView/isShownForHealth``).
    private(set) var toldHidden = false

    init(page: any PageChromiumPage, bridge: ChromiumPageHostBridge, clock: any Clock<Duration>) {
        self.page = page
        self.bridge = bridge
        deadline = DemandTimer(owner: "page.chromium.deadline", clock: clock)
    }

    /// Tells the page whether it shows, and keeps the answer: the page view's one call (``PageWebView/setChromiumVisibility(_:)``).
    func setVisible(_ visible: Bool) {
        page.setVisible(visible)
        shows = visible
        toldHidden = !visible
    }

    /// Stops the bridge and closes the page. Idempotent.
    func end() {
        questionKeys?.invalidate()
        hangWatch?.cancel()
        hangRestart?.cancel()
        deadline.cancel()
        bridge.uninstall()
        page.onEvent = nil
        page.resources = nil
        page.contentView.removeFromSuperview()
        page.close()
    }
}
