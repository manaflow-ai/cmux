/// The Chromium side of one ``PageWebView`` in Chromium mode: the page, its bridge and the
/// deadline by which the page must reach the host (else the view falls back to WebKit).
@MainActor
final class PageChromiumSession {
    let page: any PageChromiumPage
    let bridge: ChromiumPageHostBridge
    /// Cancelled when the page reaches the host or the session ends.
    var deadline: Task<Void, Never>?

    init(page: any PageChromiumPage, bridge: ChromiumPageHostBridge) {
        self.page = page
        self.bridge = bridge
    }

    /// Stops the bridge and closes the page. Idempotent.
    func end() {
        deadline?.cancel()
        deadline = nil
        bridge.uninstall()
        page.onEvent = nil
        page.contentView.removeFromSuperview()
        page.close()
    }
}
