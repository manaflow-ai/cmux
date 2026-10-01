import Foundation
import WebKit

/// Keeps the web view on the bundled page. A clicked http(s) link opens
/// outside the pane; every other navigation is cancelled.
final class AgentPaneNavigation: NSObject, WKNavigationDelegate {
    weak var view: AgentPaneView?

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let view else { return .cancel }
        switch Self.decision(for: action.request.url, page: view.pageURL, userClicked: action.navigationType == .linkActivated) {
        case .allow:
            return .allow
        case .openOutside(let url):
            view.openURL(url)
            return .cancel
        case .cancel:
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        view?.applyTheme()
    }

    /// A crashed web content process leaves a blank pane; reload the page,
    /// which asks for a fresh handshake and reattaches the session.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let view else { return }
        webView.loadFileURL(view.pageURL, allowingReadAccessTo: view.pageURL.deletingLastPathComponent())
    }

    enum Decision: Equatable {
        case allow
        case openOutside(URL)
        case cancel
    }

    static func decision(for url: URL?, page: URL, userClicked: Bool) -> Decision {
        guard let url else { return .cancel }
        if AgentPaneBridge.isTrusted(url, page: page) { return .allow }
        if userClicked, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { return .openOutside(url) }
        return .cancel
    }
}
