public import WebKit
import CmuxNextWakeups

@MainActor
extension PageWebView {
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        documentCommitted()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        documentFinished()
    }

    /// A new main-frame document committed (either engine).
    func documentCommitted() {
        #if DEBUG
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
        refreshDocumentState()
        resumeLoadWaiters()
    }

    /// Sends the document the host's whole state: the interface scale, the theme (and with it the
    /// glass still) and the `data-*` attributes. A new document needs it, and so does a Chromium
    /// page that thawed after a state script was skipped while it was frozen.
    func refreshDocumentState() {
        applyUIScale()
        applyTheme(force: true)
        applyLiveDocumentAttributes()
    }
}
