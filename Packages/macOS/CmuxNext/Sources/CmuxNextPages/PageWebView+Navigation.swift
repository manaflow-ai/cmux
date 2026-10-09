import WebKit

@MainActor
extension PageWebView {
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        // A new document: the old one's subscriptions and host calls end with it, and it has not
        // painted yet.
        router.reset()
        _ = claimState.end()
        loaded = false
        paintedUptime = nil
        let bridge = bridge
        router.send = { envelope in bridge.evaluate(PageRouter.receiveScript(envelope)) }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        loaded = true
        applyUIScale()
        applyTheme(force: true)
        applyLiveDocumentAttributes()
        resumeLoadWaiters()
    }
}
