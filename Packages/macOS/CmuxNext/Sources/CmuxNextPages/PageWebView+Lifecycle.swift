import CmuxNextDesign
public import WebKit

@MainActor
extension PageWebView {
    /// The tab closed: cancels subscriptions and stops the bridge.
    public func close() {
        isClosed = true
        _ = claimState.end()
        router.close()
        bridge.uninstall()
        endChromium()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: PagePaintProbe.handlerName, contentWorld: .page)
        resumeLoadWaiters()
        webView.stopLoading()
        WebViewRetirement.retire(webView)
    }

    /// Waits for the current document to finish loading or fail, and for a pending claim to be
    /// acknowledged (or its fallback reload to finish).
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
        resumeLoadWaiters()
    }

    // crash-allow: WebKit delegate signature uses nullable navigation handles.
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        resumeLoadWaiters()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webContentEnded(PageTermination(reason: .unknown, pid: PageTermination.webContentPid(of: webView)))
    }

    /// WebKit's reason for the end (`WKNavigationDelegatePrivate`); a WebKit that has it calls this
    /// instead of ``webViewWebContentProcessDidTerminate(_:)``.
    @objc(_webView:webContentProcessDidTerminateWithReason:)
    public func webView(_ webView: WKWebView, webContentProcessDidTerminateWithReason reason: Int) {
        webContentEnded(PageTermination(reason: .init(webKit: reason), pid: PageTermination.webContentPid(of: webView)))
    }

    /// The WebKit page's process ended with `termination` (an injected end in tests).
    public func webContentEnded(_ termination: PageTermination) {
        // A page that shows in Chromium lives in its Chromium renderer: the end of its hidden
        // WebKit view's process ends nothing the person sees. WebKit ends every web content
        // process after its GPU process fails three times (Leo's Mac, 2026-11-01: 19 Chromium
        // chats showed the crash notice over pages that still worked, and their bridges were reset).
        guard !showsChromium else {
            logger.error("page \(self.descriptor.id, privacy: .public) hidden WebKit web content ended reason=\(termination.reason.rawValue, privacy: .public) pid=\(termination.pid); the page shows in Chromium, nothing ended")
            return
        }
        lastTermination = termination.withPid(fallback: knownWebContentPid)
        contentProcessTerminated()
    }

    /// The page's web content process ended (either engine): reload unless it keeps crashing or
    /// its host shows the crash notice instead (``reloadsAfterCrash``). Logged at error level
    /// either way, with what follows.
    func contentProcessTerminated() {
        loaded = false
        router.reset()
        guard reloadsAfterCrash else {
            // A renderer that crashed before the page reached the host leaves the Chromium start
            // deadline armed: its fallback would load the page in WebKit by itself.
            chromiumSession?.deadline.cancel()
            let termination = lastTermination ?? .unknown
            logger.error("page \(self.descriptor.id, privacy: .public) web content ended reason=\(termination.reason.rawValue, privacy: .public) pid=\(termination.pid); no automatic reload (the crash notice offers Reload)")
            onCrash?(self, false)
            return
        }
        let reloading = crashReloads.shouldReload(at: now())
        if reloading {
            logger.error("page \(self.descriptor.id, privacy: .public) web content ended; reloading automatically cause=renderer-exit")
            reloadPage()
        } else {
            logger.error("page \(self.descriptor.id, privacy: .public) keeps crashing; not reloaded")
        }
        onCrash?(self, reloading)
    }

    /// Brings back a page whose process ended, in a new process, and forgets its crashes (the
    /// host's automatic retry, or the crash notice's Reload). Chromium reloads the tab (a new
    /// renderer); WebKit loads the document, which starts a new web content process (a `reload()`
    /// does nothing for a view whose process ended before its document committed: it has no URL).
    public func reloadAfterCrashes() {
        crashReloads = PageCrashReloads()
        guard chromiumSession == nil else { return reloadPage() }
        // Chromium ended while the notice showed: the page reopens in WebKit now.
        webKitLoadsOnReload = false
        webView.load(URLRequest(url: descriptor.url(route: route)))
    }
}
