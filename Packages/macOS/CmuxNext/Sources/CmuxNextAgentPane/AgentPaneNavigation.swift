import Foundation
import WebKit

/// Keeps the web view on its page (`AgentPaneSource`): the main frame shows only the page
/// document. A clicked http(s) link opens outside the pane after a real user gesture
/// (``openOutside(_:gestures:open:)``); a frame inside the page may show a loopback web page (a
/// turn's preview card, `URL.isAgentPanePreview`); every other navigation is cancelled.
final class AgentPaneNavigation: NSObject, WKNavigationDelegate {
    weak var view: AgentPaneView?

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let view else { return .cancel }
        switch Self.decision(
            for: action.request.url,
            source: view.source,
            userClicked: action.navigationType == .linkActivated,
            mainFrame: action.targetFrame?.isMainFrame ?? true
        ) {
        case .allow:
            return .allow
        case .openOutside(let url):
            _ = Self.openOutside(url, gestures: view.model.transport.gestures, open: view.openURL)
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

    static func decision(for url: URL?, source: AgentPaneSource, userClicked: Bool, mainFrame: Bool = true) -> Decision {
        guard let url else { return .cancel }
        if mainFrame, source.isPageDocument(url) { return .allow }
        // A preview frame stays on loopback pages; a click inside it does not leave the frame. It
        // never loads the pane's own page (a dev-server pane is on loopback too), which would make
        // it same-origin with the pane.
        if !mainFrame { return url.isAgentPanePreview && !source.isTrusted(url) ? .allow : .cancel }
        if userClicked, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { return .openOutside(url) }
        return .cancel
    }
}
