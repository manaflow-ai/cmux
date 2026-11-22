public import AppKit
public import WebKit

/// One open embedded web app (`cmux.pane/1` `embed`): a web view on the app's own persistent
/// data store (`WKWebsiteDataStore(forIdentifier:)` keyed by the profile id the daemon derived
/// from the app id), so its sign-in and cookies stay in that app only and never mix with the
/// person's browser profiles or another app's. Every main-frame navigation, `window.open` and
/// redirect goes only to the url's origin and the declared origins (``AppEmbedPage/allows(_:)``);
/// anything else is cancelled. The page gets no cmux bridge.
@MainActor
public final class AppEmbedPaneHost: NSObject, WKNavigationDelegate, WKUIDelegate {
    public let view: WKWebView
    public let page: AppEmbedPage
    /// Navigations refused for leaving the declared origins (tests and probes).
    public private(set) var refused: [URL] = []

    public init(page: AppEmbedPage) {
        self.page = page
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: page.profile)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        view.load(URLRequest(url: page.url))
    }

    /// Whether a navigation to `url` in the main frame may happen. Subframes are content of an
    /// allowed page; `about:` documents are WebKit's own.
    func permits(_ url: URL?, mainFrame: Bool) -> Bool {
        guard let url else { return false }
        if !mainFrame || url.scheme?.lowercased() == "about" { return true }
        return page.allows(url)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if permits(navigationAction.request.url, mainFrame: mainFrame) {
            decisionHandler(.allow)
        } else {
            if let url = navigationAction.request.url { refused.append(url) }
            decisionHandler(.cancel)
        }
    }

    /// `window.open` (a sign-in popup): an allowed URL opens in this pane, never a new window.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if page.allows(url) { webView.load(URLRequest(url: url)) } else { refused.append(url) }
        }
        return nil
    }

    public func close() {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }
}
