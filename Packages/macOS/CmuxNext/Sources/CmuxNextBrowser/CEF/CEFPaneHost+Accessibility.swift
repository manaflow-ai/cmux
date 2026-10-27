import Foundation

/// Host mode: the shown page's accessibility in ``hostedPageView`` (task 049 of
/// plans/cmux-next/chrome-parity/p01-process.md). The page view asks at its first accessibility
/// read (ChromiumHostPageView+Accessibility.swift); this pane sends the request to the Chromium Host
/// as `cmux_shim_browser_accessibility_token`, whose REPLY carries the page's token, and keeps the
/// page view on the shown tab's browser. In process the page window is its own accessibility tree.
extension CEFPaneHost {
    /// `browser`'s tab shows: the page view's accessibility follows it.
    func showPageAccessibility(of browser: Int32) {
        guard isHostMode else { return }
        hostedPageView?.showAccessibility(of: browser)
    }

    /// Sends `request` to the host and gives `answered` the page's token, nil when the host gave none
    /// or no answer came. A token longer than `capacity` is asked for once more at its length.
    func askPageAccessibility(_ request: ChromiumHostAccessibilityRequest,
                              capacity: Int32 = ChromiumHostAccessibilityToken.initialCapacity,
                              answered: @escaping ([UInt8]?) -> Void) {
        let sent: CEFShimAnswer<ChromiumHostAccessibilityToken> = runtime.sendAsync { shim in
            shim.browserAccessibilityToken(request.browser, request.embedderPID, request.viewToken, request.windowToken, capacity)
        }
        runtime.whenAnswered(sent, label: "page accessibility token") { [weak self] reply in
            if let self, let retry = reply?.retryCapacity, retry > capacity {
                return askPageAccessibility(request, capacity: retry, answered: answered)
            }
            answered(reply?.token)
        }
    }
}

extension CEFRuntime {
    /// ``CEFAccessibility``'s switch for one browser: Chromium builds or drops the page's tree, and in
    /// host mode a shown page the host gave no token while it had none asks again, after that post.
    func applyPageAccessibility(_ browser: Int32, _ enabled: Bool) {
        setPageAccessibility(browser, enabled)
        guard enabled, let host = tabsByBrowser[browser]?.host, host.visibleTab?.browserID == browser else { return }
        host.hostedPageView?.retryRemoteAccessibility()
    }
}
