import Foundation
import WebKit

/// Keeps the web view on its page (`AgentPaneSource`). A clicked http(s) link opens
/// outside the pane; every other navigation is cancelled.
final class AgentPaneNavigation: NSObject, WKNavigationDelegate {
    weak var view: AgentPaneView?

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let view else { return .cancel }
        switch Self.decision(for: action.request.url, source: view.source, userClicked: action.navigationType == .linkActivated) {
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
        view?.applyShortcuts()
        view?.applyPreviewFeatures()
        view?.replayCustomization()
    }

    /// A crashed web content process leaves a blank pane; the view reloads
    /// the page, which asks for a fresh handshake and reattaches the session.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        view?.webContentProcessDidTerminate()
    }

    enum Decision: Equatable {
        case allow
        case openOutside(URL)
        case cancel
    }

    static func decision(for url: URL?, source: AgentPaneSource, userClicked: Bool) -> Decision {
        guard let url else { return .cancel }
        if source.isTrusted(url) { return .allow }
        if userClicked, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { return .openOutside(url) }
        return .cancel
    }
}
