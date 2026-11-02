import CmuxNextPages
import Foundation
import WebKit

/// Keeps the web view on its page (`AgentPaneSource`): the main frame shows only the page
/// document. A clicked http(s) link, or a cmux app link (opened in the app), opens outside the pane after a real user gesture
/// (``openOutside(_:gestures:open:)``); a frame inside the page may show a loopback web page (a
/// turn's preview card, `URL.isAgentPanePreview`) or the render frame (a render card,
/// `AgentPaneRenderFrame`); every other navigation is cancelled.
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
            sourceFrameURL: action.sourceFrame.request.url,
            targetFrameURL: action.targetFrame?.request.url
        ) {
        case .allow:
            decisionHandler(.allow)
        case .openOutside(let url):
            let modifiers = action.modifierFlags
            _ = Self.openOutside(url, gestures: view.model.transport.gestures) { view.openURL($0, modifiers) }
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
        let pid = PageTermination.webContentPid(of: webView)
        if pid != 0 { view?.knownWebContentPid = pid }
        view?.pageLoadedAgain()
        view?.applyTheme(force: true)
        // The initial zoom can run before WebKit has a document. Reapply it after the
        // document exists so the interface scale and page scale are visible on first paint.
        view?.applyZoom()
        view?.applyShortcuts()
        view?.applyPreviewFeatures()
        if let view { AgentPaneSessionStatus.push(to: view) }
        if let view { AgentPaneSuggestedTasks.shared.push(to: view) }
        view?.applyEditedFiles()
        view?.replayCustomization()
    }

    /// A crashed web content process leaves a blank pane; the view shows the crash notice, whose
    /// Reload asks for a fresh handshake and reattaches the session (only when pressed).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        view?.webContentProcessDidTerminate(PageTermination(reason: .unknown, pid: PageTermination.webContentPid(of: webView)))
    }

    /// The same with WebKit's reason (`WKNavigationDelegatePrivate`); a WebKit that has it calls
    /// this instead of ``webViewWebContentProcessDidTerminate(_:)``.
    @objc(_webView:webContentProcessDidTerminateWithReason:)
    func webView(_ webView: WKWebView, webContentProcessDidTerminateWithReason reason: Int) {
        view?.webContentProcessDidTerminate(PageTermination(reason: .init(webKit: reason), pid: PageTermination.webContentPid(of: webView)))
    }

    enum Decision: Equatable {
        case allow
        case openOutside(URL)
        case cancel
    }

    static func decision(for url: URL?, source: AgentPaneSource, userClicked: Bool, mainFrame: Bool = true,
                         sourceFrameURL: URL? = nil, targetFrameURL: URL? = nil) -> Decision {
        // CSP blocks resource loads, but not self-navigation. An artifact may never navigate
        // itself, a sibling or the pane, including to the otherwise allowed loopback previews.
        if AgentPaneRenderFrame.isArtifact(sourceFrameURL) || AgentPaneRenderFrame.isArtifact(targetFrameURL) {
            return .cancel
        }
        // A passive artifact is a sandboxed srcdoc frame. Its initial about:srcdoc load is allowed,
        // but a navigation originating there must not reach an allowed loopback preview or the pane.
        if sourceFrameURL?.absoluteString == "about:srcdoc" {
            return .cancel
        }
        if targetFrameURL?.absoluteString == "about:srcdoc", url?.absoluteString != "about:srcdoc" {
            return .cancel
        }
        guard let url else { return .cancel }
        if mainFrame, source.isPageDocument(url) { return .allow }
        // A preview frame stays on loopback pages; a click inside it does not leave the frame. It
        // never loads the pane's own page (a dev-server pane is on loopback too), which would make
        // it same-origin with the pane.
        if !mainFrame {
            // Only the pane may create an artifact's script-capable frame. A loopback preview
            // must not acquire that endpoint by creating a nested frame of its own.
            if AgentPaneRenderFrame.isArtifact(url) {
                if case .bundled = source, source.isTrusted(sourceFrameURL) { return .allow }
                return .cancel
            }
            if case .bundled = source, AgentPaneRenderFrame.isFrame(url) { return .allow }
            // A question's HTML option preview (question/HtmlPreview.tsx): the pane's own
            // document, written into a sandboxed frame with no scripts. It loads nothing itself.
            if url.absoluteString == "about:srcdoc" { return .allow }
            return url.isAgentPanePreview && !source.isTrusted(url) ? .allow : .cancel
        }
        if userClicked, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { return .openOutside(url) }
        if userClicked, isCmuxAppLink(url) { return .openOutside(url) }
        return .cancel
    }
}
