import AppKit
public import WebKit

@MainActor
extension PageWebView {
    // Completion-handler form: Xcode 26.6's compiler crashes emitting the ObjC
    // thunk for async delegate methods.
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(policy(for: action))
    }

    private func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        let url = action.request.url
        switch PageNavigation.policy(for: url, page: descriptor, userClicked: action.navigationType == .linkActivated,
                                     mainFrame: action.targetFrame?.isMainFrame ?? true, hook: onNavigate) {
        case .allow:
            return .allow
        case .openExternal:
            if let url { onOpenExternal?(url) }
            return .cancel
        case .cancel:
            return .cancel
        }
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new document: the old one's subscriptions and host calls end with it, and it has not
        // painted yet.
        router.reset()
        _ = claimState.end()
        loaded = false
        paintedUptime = nil
        let bridge = bridge
        router.send = { envelope in bridge.evaluate(PageRouter.receiveScript(envelope)) }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        applyUIScale()
        applyTheme(force: true)
        applyLiveDocumentAttributes()
        resumeLoadWaiters()
    }
}
