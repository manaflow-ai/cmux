import CmuxNextPages
import Foundation
import WebKit

/// Keeps the web view on its page (`AgentPaneSource`): the main frame shows only the page
/// document. A clicked http(s) link opens outside the pane after a real user gesture
/// (``openOutside(_:gestures:open:)``); a frame inside the page may show a loopback web page (a
/// turn's preview card, `URL.isAgentPanePreview`) or the render frame (a render card,
/// `AgentPaneRenderFrame`, loaded once); every other navigation is cancelled.
final class AgentPaneNavigation: NSObject, WKNavigationDelegate {
    weak var view: AgentPaneView?

    /// Answered in this turn: the `async` form waits for a task hop, behind the launch's main
    /// actor work, before the page's navigation can start (bd cx-z9kz0).
    @objc(webView:decidePolicyForNavigationAction:decisionHandler:)
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let view else { return decisionHandler(.cancel) }
        switch Self.decision(
            for: action.request.url,
            source: view.source,
            userClicked: action.navigationType == .linkActivated,
            mainFrame: action.targetFrame?.isMainFrame ?? true,
            targetFrameURL: action.targetFrame?.request.url,
            sourceFrameURL: action.sourceFrame.request.url
        ) {
        case .allow:
            decisionHandler(.allow)
        case .openOutside(let url):
            let other = LinkRouter.isOtherTarget(action.modifierFlags)
            _ = Self.openOutside(url, gestures: view.model.transport.gestures) { view.openURL($0, other) }
            decisionHandler(.cancel)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    /// A New Tab page gets its context as its document commits, so its first render draws the
    /// page with no `newTab.context` round trip (`injectedNewTabContext`, bd cx-z9kz0). The host
    /// gives what is true at this load: a reloaded page that became a chat gets none.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        guard let model = view?.model, model.sessionId == nil, let page = model.newTab,
              let data = try? JSONEncoder().encode(page), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__cmuxNewTabContext = \(json);", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        AgentPaneLaunchTimings.shared.mark("agent_pane.page_loaded")
        AgentPaneView.finishWarmup()
        view?.applyTheme(force: true)
        // The initial zoom can run before WebKit has a document. Reapply it after the
        // document exists so the interface scale and page scale are visible on first paint.
        view?.applyZoom()
        view?.applyShortcuts()
        view?.applyPreviewFeatures()
        if let view { AgentPaneSuggestedTasks.shared.push(to: view) }
        view?.applyEditedFiles()
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

    static func decision(for navigation: PageNavigation, source: AgentPaneSource) -> Decision {
        decision(for: navigation.url, source: source, userClicked: navigation.userClicked,
                 mainFrame: navigation.mainFrame, targetFrameURL: navigation.targetFrameURL,
                 sourceFrameURL: navigation.sourceFrameURL)
    }

    static func decision(for url: URL?, source: AgentPaneSource, userClicked: Bool, mainFrame: Bool = true,
                         targetFrameURL: URL? = nil, sourceFrameURL: URL? = nil) -> Decision {
        guard let url else { return .cancel }
        // WKFrameInfo is a snapshot, not a stable iframe identity. Its current request is the
        // frame's load state: initially blank, then the render document, including after
        // document.open/write. Check the target too so a parent cannot navigate a loaded render.
        // RenderCard uses srcdoc on the shared page host; PreviewCard always uses a loopback URL.
        if [targetFrameURL, sourceFrameURL].contains(where: { current in
            guard let current else { return false }
            return isRenderFrame(current, source: source) || (current.scheme == "about" && current.path == "srcdoc")
        }) { return .cancel }
        if mainFrame, source.isPageDocument(url) { return .allow }
        // A preview frame stays on loopback pages; a click inside it does not leave the frame. It
        // never loads the pane's own page (a dev-server pane is on loopback too), which would make
        // it same-origin with the pane.
        if !mainFrame {
            if isRenderFrame(url, source: source) {
                return targetFrameURL == nil || targetFrameURL?.absoluteString == "about:blank" ? .allow : .cancel
            }
            return url.isAgentPanePreview && !source.isTrusted(url) ? .allow : .cancel
        }
        if userClicked, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { return .openOutside(url) }
        return .cancel
    }

    private static func isRenderFrame(_ url: URL, source: AgentPaneSource) -> Bool {
        switch source {
        case .bundled:
            return AgentPaneRenderFrame.isFrame(url)
        case .devServer:
            return source.isTrusted(url) && url.user == nil && url.password == nil && url.path == "/__cmux-render-frame"
        }
    }
}
