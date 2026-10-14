public import Foundation
import WebKit

/// Navigation commands that name the navigation they start, and the raw
/// navigation events, for callers that wait on one navigation (the browser
/// automation driver's load waits). The state machine keeps only the active
/// navigation; these keep every id, so a waiter can tell its own commit from
/// another document's (a fresh web view's about:blank, a superseded load).
extension WebKitTab {
    /// Loads `url`; returns the id the navigation's events carry, nil when
    /// WebKit started none (closed tab, or a load WebKit refused).
    @discardableResult
    public func startLoad(_ url: URL) -> BrowserNavigationID? {
        guard !isClosed else { return nil }
        let navigation = if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        return register(navigation)
    }

    @discardableResult
    public func startGoBack() -> BrowserNavigationID? { register(webView.goBack()) }

    @discardableResult
    public func startGoForward() -> BrowserNavigationID? { register(webView.goForward()) }

    @discardableResult
    public func startReload() -> BrowserNavigationID? {
        if webView.url == nil, let url = state.url { return startLoad(url) }
        return register(webView.reload())
    }

    /// Calls `handler` with every navigation event as the tab applies it,
    /// including those of superseded navigations, which the state machine
    /// ignores. Stop with `removeNavigationObserver`.
    public func observeNavigationEvents(_ handler: @escaping (BrowserNavigationEvent) -> Void) -> UUID {
        let id = UUID()
        navigationObservers[id] = handler
        return id
    }

    public func removeNavigationObserver(_ id: UUID) {
        navigationObservers[id] = nil
    }

    /// The id for a navigation WebKit returned; its delegate callbacks,
    /// which come later, find the same id.
    private func register(_ navigation: WKNavigation?) -> BrowserNavigationID? {
        navigation.flatMap { navigationID(for: $0, creating: true) }
    }
}
