public import WebKit
import CmuxNextWakeups

@MainActor
extension PageWebView {
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        documentCommitted()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        let pid = PageTermination.webContentPid(of: webView)
        if pid != 0 { knownWebContentPid = pid }
        documentFinished()
    }

    /// A new main-frame document committed (either engine).
    func documentCommitted() {
        #if DEBUG || CMUX_BENCH_HOOKS
        traceMark(.committed)
        #endif
        // A new document: the old one's subscriptions and host calls end with it, and it has not
        // painted yet.
        router.reset()
        _ = claimState.end()
        loaded = false
        paintedUptime = nil
        repaintsAtNextLayout = false
        let scripts = scripts
        router.send = { envelope in scripts.send(envelope) }
    }

    /// The document finished loading (either engine).
    func documentFinished() {
        loaded = true
        applyUIScale()
        applyTheme(force: true)
        applyLiveDocumentAttributes()
        resumeLoadWaiters()
        onDocumentLoaded?()
    }
}
