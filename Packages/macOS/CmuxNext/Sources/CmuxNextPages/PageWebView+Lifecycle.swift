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
            logger.error("page \(self.descriptor.id, privacy: .public) web content ended; no automatic reload (the crash notice offers Reload)")
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

    /// Reloads a page that stopped reloading after crashes, and forgets those crashes (the crash
    /// notice's Reload button).
    public func reloadAfterCrashes() {
        crashReloads = PageCrashReloads()
        guard webKitLoadsOnReload else { return reloadPage() }
        // Chromium ended while the notice showed: the page reopens in WebKit now.
        webKitLoadsOnReload = false
        webView.load(URLRequest(url: descriptor.url(route: route)))
    }
}
