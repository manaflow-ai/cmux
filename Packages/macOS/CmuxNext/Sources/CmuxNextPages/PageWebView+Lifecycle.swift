public import WebKit

@MainActor
extension PageWebView {
    /// The tab closed: cancels subscriptions and stops the bridge.
    public func close() {
        _ = claimState.end()
        router.close()
        bridge.uninstall()
        endChromium()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: PagePaintProbe.handlerName, contentWorld: .page)
        resumeLoadWaiters()
        traceOpenEnd(.closedBeforePaint)
    }

    /// Waits for the current document to finish loading or fail, and for a pending claim to be acknowledged (or its fallback reload to finish).
    public func waitUntilLoaded() async {
        guard !loaded || claimState.pending else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loadWaiters.append(continuation)
        }
    }

    func resumeLoadWaiters() {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // crash-allow: WebKit delegate signature uses nullable navigation handles.
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        loadState.set(loading: false, page: self)
        resumeLoadWaiters()
    }

    // crash-allow: WebKit delegate signature uses nullable navigation handles.
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        loadState.set(loading: false, page: self)
        resumeLoadWaiters()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        contentProcessTerminated()
    }

    /// The page's web content process ended (either engine): ``PageCrashRecovery`` reloads it now,
    /// when it shows, or not at all once it keeps crashing.
    func contentProcessTerminated() {
        loaded = false
        router.reset()
        crash.crashed(self)
    }

    /// Reloads a page that stopped reloading after crashes, and forgets those crashes (the crash notice's Reload button).
    public func reloadAfterCrashes() {
        crash.forgive(self)
        reloadPage()
    }
}
