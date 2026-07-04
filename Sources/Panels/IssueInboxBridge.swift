import AppKit
import Foundation
import WebKit

enum IssueInboxBridgeContract {
    static let handlerName = "cmuxIssueInbox"
}

@MainActor
final class IssueInboxWebView: WKWebView {
    var onPointerDown: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        super.mouseDown(with: event)
    }
}

@MainActor
final class IssueInboxBridge: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    var webView: IssueInboxWebView?
    private var panelId = UUID()
    private var workspaceId = UUID()
    private var theme: AgentSessionWebTheme = .resolve(appearance: .fromConfig(GhosttyConfig.load()))
    private var trustedShellURL: URL?
    private var hasFinishedNavigation = false
    private var hasCompletedVisiblePaintFlush = false
    private var isPanelFocused = false

    func bind(
        panelId: UUID,
        workspaceId: UUID,
        theme: AgentSessionWebTheme,
        isFocused: Bool
    ) {
        self.panelId = panelId
        self.workspaceId = workspaceId
        isPanelFocused = isFocused
        let themeChanged = self.theme != theme
        self.theme = theme
        if themeChanged {
            applyThemeToLoadedPage()
        }
    }

    func ensureWebView(onPointerDown: @escaping () -> Void) -> IssueInboxWebView {
        if let webView {
            webView.onPointerDown = onPointerDown
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        configuration.userContentController.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: IssueInboxBridgeContract.handlerName
        )
        let webView = IssueInboxWebView(frame: .zero, configuration: configuration)
        webView.onPointerDown = onPointerDown
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(macOS 13.3, *) {
#if DEBUG
            webView.isInspectable = true
#else
            webView.isInspectable = false
#endif
        }
        self.webView = webView
        return webView
    }

    func loadShellIfNeeded() {
        guard trustedShellURL == nil else { return }
        guard let webView, webView.window != nil else { return }
        guard let resourceDirectoryURL = Bundle.main.resourceURL else { return }
        let indexURL = Self.shellURL(resourceDirectoryURL: resourceDirectoryURL)
        trustedShellURL = Self.normalizedTrustedFileURL(indexURL)
        webView.loadFileURL(indexURL, allowingReadAccessTo: resourceDirectoryURL)
        hasFinishedNavigation = false
        hasCompletedVisiblePaintFlush = false
    }

    func focus() {
        guard let webView else { return }
        _ = webView.window?.makeFirstResponder(webView)
    }

    func close() {
        if let webView {
            webView.removeFromSuperview()
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: IssueInboxBridgeContract.handlerName,
                contentWorld: .page
            )
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.onPointerDown = nil
        }
        webView = nil
        trustedShellURL = nil
        hasFinishedNavigation = false
        hasCompletedVisiblePaintFlush = false
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard isTrustedBridgeFrame(message.frameInfo) else {
            replyHandler(["ok": false, "error": [:]], nil)
            return
        }
        Task { @MainActor in
            do {
                let request = try IssueInboxBridgeRequest(body: message.body)
                let reply = try await self.handle(request)
                replyHandler(["ok": true, "value": reply], nil)
            } catch let error as IssueInboxBridgeError {
                replyHandler(["ok": false, "error": ["code": error.code, "userMessage": error.message]], nil)
            } catch {
                replyHandler(["ok": false, "error": ["userMessage": error.localizedDescription]], nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasFinishedNavigation = true
        applyThemeToLoadedPage()
        if isPanelFocused {
            focus()
        }
        flushInitialPaint(for: webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let isMainFrameNavigation = navigationAction.targetFrame?.isMainFrame ?? true
        guard isMainFrameNavigation else {
            decisionHandler(.allow)
            return
        }
        if Self.isTrustedShellURL(url, expected: trustedShellURL) {
            decisionHandler(.allow)
            return
        }
        if isInPageFragment(url, currentURL: webView.url) {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func flushVisiblePaintIfReady() {
        guard hasFinishedNavigation,
              !hasCompletedVisiblePaintFlush,
              let webView,
              webView.window != nil,
              !webView.bounds.isEmpty else {
            return
        }
        flushInitialPaint(for: webView) { [weak self] in
            self?.hasCompletedVisiblePaintFlush = true
        }
    }

    private func handle(_ request: IssueInboxBridgeRequest) async throws -> Any {
        switch request.method {
        case "snapshot":
            var payload = TerminalController.shared.issueInboxListPayload()
            payload["panel_id"] = panelId.uuidString
            payload["workspace_id"] = workspaceId.uuidString
            payload["theme"] = theme.dictionary
            payload["labels"] = IssueInboxWebLabels.dictionary
            return payload
        case "refresh":
            let refreshResult = await TerminalController.shared.issueInboxRefreshPayload()
            let value = try v2Value(refreshResult)
            sendRefreshCompleted()
            return value
        case "spawn":
            let issueID = try request.requiredString("issueId")
            var params: [String: Any] = ["issue_id": issueID]
            if let agent = request.string("agent") {
                params["agent"] = agent
            }
            return try v2Value(TerminalController.shared.issueInboxSpawnWorkspace(
                issueID: issueID,
                cwd: nil,
                params: params,
                forceFocus: true
            ))
        case "openExternal":
            let rawURL = try request.requiredString("url")
            guard let url = URL(string: rawURL) else {
                throw IssueInboxBridgeError(code: "invalid_params", message: "Invalid URL")
            }
            return ["opened": NSWorkspace.shared.open(url)]
        case "openConfig":
            return try v2Value(TerminalController.shared.issueInboxOpenConfigPayload())
        default:
            throw IssueInboxBridgeError(code: "method_not_found", message: "Unsupported Issue Inbox bridge method")
        }
    }

    private func v2Value(_ result: V2CallResult) throws -> Any {
        switch result {
        case .ok(let payload):
            return payload
        case .err(let code, let message, let data):
            throw IssueInboxBridgeError(code: code, message: message, data: data)
        }
    }

    private func sendRefreshCompleted() {
        let script = """
        window.dispatchEvent(new CustomEvent("cmuxIssueInboxRefreshCompleted"));
        """
        webView?.evaluateJavaScript(script) { _, _ in }
    }

    private func applyThemeToLoadedPage() {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: theme.dictionary),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        webView.evaluateJavaScript("window.cmuxIssueInboxBridge?.applyTheme(\(json));") { _, _ in }
    }

    private func flushInitialPaint(for webView: WKWebView, completion: (() -> Void)? = nil) {
        let script = """
        (() => {
          void (document.body && document.body.innerText);
          void (document.documentElement && document.documentElement.scrollHeight);
          return true;
        })()
        """
        webView.evaluateJavaScript(script) { _, _ in
            webView.setNeedsDisplay(webView.bounds)
            completion?()
        }
    }

    private func isTrustedBridgeFrame(_ frameInfo: WKFrameInfo) -> Bool {
        guard frameInfo.isMainFrame else { return false }
        return Self.isTrustedShellURL(frameInfo.request.url, expected: trustedShellURL)
    }

    private func isInPageFragment(_ url: URL, currentURL: URL?) -> Bool {
        guard url.fragment != nil else { return false }
        if (url.scheme == nil || url.scheme == "about"), (url.host ?? "").isEmpty {
            return true
        }
        guard let currentURL else { return false }
        if url.isFileURL, currentURL.isFileURL {
            return (url.path as NSString).standardizingPath ==
                (currentURL.path as NSString).standardizingPath
        }
        return url.scheme == currentURL.scheme &&
            url.host == currentURL.host &&
            url.path == currentURL.path
    }

    nonisolated static func shellURL(resourceDirectoryURL: URL) -> URL {
        ["markdown-viewer", "webviews-app", "issue-inbox.html"].reduce(resourceDirectoryURL) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
    }

    nonisolated static func isTrustedShellURL(_ candidate: URL?, expected: URL?) -> Bool {
        guard let candidate = normalizedTrustedFileURL(candidate),
              let expected = normalizedTrustedFileURL(expected) else {
            return false
        }
        return candidate == expected
    }

    nonisolated static func normalizedTrustedFileURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

private struct IssueInboxBridgeRequest {
    var method: String
    var params: [String: Any]

    init(body: Any) throws {
        guard let object = body as? [String: Any],
              let method = object["method"] as? String else {
            throw IssueInboxBridgeError(code: "invalid_request", message: "Invalid bridge request")
        }
        self.method = method
        self.params = object["params"] as? [String: Any] ?? [:]
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else {
            throw IssueInboxBridgeError(code: "invalid_params", message: "\(key) is required")
        }
        return value
    }

    func string(_ key: String) -> String? {
        let value = (params[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

private struct IssueInboxBridgeError: Error {
    var code: String
    var message: String
    var data: Any?
}

private enum IssueInboxWebLabels {
    static var dictionary: [String: String] {
        [
            "title": String(localized: "issueInbox.title", defaultValue: "Issue Inbox"),
            "searchPlaceholder": String(localized: "issueInbox.web.searchPlaceholder", defaultValue: "Search issues"),
            "refresh": String(localized: "issueInbox.web.refresh", defaultValue: "Refresh"),
            "refreshing": String(localized: "issueInbox.web.refreshing", defaultValue: "Refreshing"),
            "statusOpen": String(localized: "issueInbox.web.status.open", defaultValue: "Open"),
            "statusClosed": String(localized: "issueInbox.web.status.closed", defaultValue: "Closed"),
            "statusAll": String(localized: "issueInbox.web.status.all", defaultValue: "All"),
            "providerAll": String(localized: "issueInbox.web.provider.all", defaultValue: "All providers"),
            "providerGithub": String(localized: "issueInbox.web.provider.github", defaultValue: "GitHub"),
            "providerLinear": String(localized: "issueInbox.web.provider.linear", defaultValue: "Linear"),
            "spawn": String(localized: "issueInbox.web.spawn", defaultValue: "Spawn"),
            "agentClaude": String(localized: "issueInbox.web.agent.claude", defaultValue: "Claude"),
            "agentCodex": String(localized: "issueInbox.web.agent.codex", defaultValue: "Codex"),
            "agentShell": String(localized: "issueInbox.web.agent.shell", defaultValue: "Shell only"),
            "openConfig": String(localized: "issueInbox.web.openConfig", defaultValue: "Open config"),
            "emptyTitle": String(localized: "issueInbox.web.empty.title", defaultValue: "Configure Issue Inbox"),
            "emptyBody": String(
                localized: "issueInbox.web.empty.body",
                defaultValue: "Add GitHub or Linear sources in ~/.config/cmux/issue-inbox.json."
            ),
            "emptyExample": String(localized: "issueInbox.web.empty.example", defaultValue: "Minimal example"),
            "emptyResults": String(localized: "issueInbox.web.emptyResults", defaultValue: "No issues match the current filters."),
            "sourceFailed": String(localized: "issueInbox.web.error.sourceFailed", defaultValue: "Could not refresh this source."),
            "staleRows": String(localized: "issueInbox.web.error.staleRows", defaultValue: "Showing cached rows where available."),
            "details": String(localized: "issueInbox.web.details", defaultValue: "Details"),
            "updated": String(localized: "issueInbox.web.updated", defaultValue: "Updated"),
            "showing": String(localized: "issueInbox.web.showing", defaultValue: "Showing {shown} of {total}"),
            "openInBrowser": String(localized: "issueInbox.web.openInBrowser", defaultValue: "Open in browser"),
            "loading": String(localized: "issueInbox.web.loading", defaultValue: "Loading issues"),
            "requestFailed": String(localized: "issueInbox.web.requestFailed", defaultValue: "Issue Inbox request failed."),
        ]
    }
}
