public import WebKit
import CmuxNextWakeups

@MainActor
extension PageWebView {
    // crash-allow: WebKit delegate signature uses nullable navigation handles.
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        documentStarted()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        documentCommitted()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        let pid = PageTermination.webContentPid(of: webView)
        if pid != 0 { knownWebContentPid = pid }
        documentFinished()
    }

    /// A main-frame document started loading (either engine): a reload the host started (``reloadPage()``,
    /// ``WebDevOverrideWatcher``'s reload of every served view, crash recovery, an app health repair) or any
    /// load WebKit began. App health reads the page as loading, not hung, until the document loads: a web source
    /// change reloaded every chat at once on a loaded Mac, the documents took 44 s and 72 s, and health reloaded
    /// them 8 s in and then restarted their renderer (cosmic-gray, 2026-11-22 06:41:33Z).
    func documentStarted() {
        healthFeed?.pageNavigationStarted(self)
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
        watchOverlayStart()
        onDocumentWillChange?(.committed)
    }

    /// The document finished loading (either engine).
    func documentFinished() {
        loaded = true
        // A restart that only reloaded (the renderer was never ended) is over: a later crash shows its notice.
        rendererRestartPending = false
        applyUIScale()
        applyTheme(force: true)
        applyLanguage()
        applyLiveDocumentAttributes()
        resumeLoadWaiters()
        onDocumentLoaded?()
        healthFeed?.pageLoaded(self)
    }
}
