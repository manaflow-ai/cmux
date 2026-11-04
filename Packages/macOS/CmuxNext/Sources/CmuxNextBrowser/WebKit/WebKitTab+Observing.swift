public import CmuxNextWakeups
import Foundation
import WebKit

/// The web view's reports (KVO) and the tab's node.
///
/// The URL, title, history and security are the tab's model (the daemon's record, history, the rows): they apply in
/// the report's turn, in order with the navigation delegate's callbacks, shown or hidden, as a WebContents'
/// `NavigationStateChanged` updates its model at once (content/browser/web_contents/web_contents_impl.cc). Load
/// progress only draws the bar: a hidden tab applies the latest when its node shows (``progressDidChange()``).
extension WebKitTab: BrowserTabNodeAdopting {
    public func adoptNode(_ node: VisibilityNode) {
        guard node !== visibilityNode else { return }
        visibilityNode?.cancelDeferred(key: Self.progressKey)
        visibilityNode = node
    }

    func observeWebView() {
        observations = [
            watch(\.url) { $0.apply(.urlChanged($0.webView.url)) },
            watch(\.title) { $0.offerTitle($0.webView.title) },
            watch(\.estimatedProgress) { $0.progressDidChange() },
            watch(\.canGoBack) { $0.syncHistory() },
            watch(\.canGoForward) { $0.syncHistory() },
            watch(\.hasOnlySecureContent) { $0.syncSecurity() },
        ]
    }

    /// One KVO of the web view, delivered to `changed` on the main thread.
    private func watch<Value>(_ property: KeyPath<WKWebView, Value>,
                              _ changed: @escaping @MainActor @Sendable (WebKitTab) -> Void) -> NSKeyValueObservation {
        // raw-observer-allow: WKWebView reports its URL, title, progress, history and security only through KVO (no notice); it is this tab's own web view, no window's or app's
        webView.observe(property, options: [.new]) { @Sendable [weak self] _, _ in
            // main-hop-allow: WebKit changes these on the main thread, so the change applies inline in that turn, in order with the navigation delegate's callbacks; only an off-main change hops
            MainDelivery().run {
                guard let self else { return }
                changed(self)
            }
        }
    }

    /// The web view's load progress moved: the bar shows it now, or once when the tab's node next shows (the value
    /// read then). Chrome sends a WebContents' load progress at most every 100 ms
    /// (`WebContentsImpl::SendChangeLoadProgress`); a hidden tab here sends none until it shows.
    func progressDidChange() {
        guard let node = visibilityNode else { return apply(.progress(webView.estimatedProgress)) }
        node.deferUntilVisible(key: Self.progressKey) { [weak self] in
            guard let self, !self.isClosed else { return }
            self.apply(.progress(self.webView.estimatedProgress))
        }
    }

    /// The ``visibilityNode`` key of a hidden tab's progress.
    static let progressKey = "WebKitTab.progress"

    func syncHistory() {
        restored.syncAvailability()
        let list = webView.backForwardList
        apply(.historyListed(back: list.backList.suffix(Self.historyListLimit).map(\.url.absoluteString),
                             forward: list.forwardList.prefix(Self.historyListLimit).map(\.url.absoluteString)))
    }

    /// URLs kept on each side of the current entry (the daemon's tab record holds 20).
    static let historyListLimit = 20

    func syncSecurity() {
        guard !isClosed, state.phase == .committed || state.phase == .finished else { return }
        apply(.securityChanged(BrowserTabStateMachine.security(
            for: webView.url, hasOnlySecureContent: webView.hasOnlySecureContent,
            certificateBypassed: engine?.loadedPastCertificateWarning(self) ?? false)))
    }
}
