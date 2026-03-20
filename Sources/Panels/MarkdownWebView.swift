import AppKit
import SwiftUI
import WebKit
import Combine

/// A WKWebView-based markdown renderer that supports find-in-page via BrowserFindJavaScript.
/// Replaces MarkdownUI for rendering when find-in-page needs highlighting and scroll-to-match.
struct MarkdownWebView: NSViewRepresentable {
    let panelId: UUID
    let content: String
    let filePath: String
    let searchState: MarkdownSearchState?
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.panelId = panelId
        context.coordinator.searchState = searchState

        loadContent(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        let searchStateChanged = coordinator.searchState !== searchState
        coordinator.searchState = searchState

        // Re-setup needle observer when searchState changes (e.g. nil → non-nil on Cmd-F)
        if searchStateChanged {
            coordinator.setupNeedleObserver()
        }

        // Clear highlights when search is dismissed (searchState goes nil)
        if searchState == nil && searchStateChanged {
            webView.evaluateJavaScript(BrowserFindJavaScript.clearScript()) { _, _ in }
        }

        // Reload content if it changed
        if coordinator.lastContent != content || coordinator.lastColorScheme != colorScheme {
            coordinator.lastContent = content
            coordinator.lastColorScheme = colorScheme
            loadContent(in: webView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func loadContent(in webView: WKWebView) {
        let isDark = colorScheme == .dark
        let html = Self.htmlTemplate(content: content, isDark: isDark)
        // Use the markdown file's directory as baseURL so relative links/images resolve.
        let baseURL = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    // MARK: - HTML Template

    static func htmlTemplate(content: String, isDark: Bool) -> String {
        // Base64-encode raw markdown to avoid injection (e.g. "</script>" in content).
        let base64Content = Data(content.utf8).base64EncodedString()
        let bg = isDark ? "#1e1e1e" : "#ffffff"
        let fg = isDark ? "rgba(255,255,255,0.9)" : "#1d1d1f"
        let codeBg = isDark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.04)"
        let codeBorder = isDark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.1)"
        let linkColor = isDark ? "#6cb4ff" : "#0066cc"
        let tableBorder = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.15)"
        let hrColor = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.1)"
        let blockquoteBorder = isDark ? "rgba(255,255,255,0.2)" : "rgba(0,0,0,0.15)"
        let blockquoteColor = isDark ? "rgba(255,255,255,0.6)" : "rgba(0,0,0,0.5)"

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
                font-size: 14px;
                line-height: 1.6;
                color: \(fg);
                background: \(bg);
                padding: 16px 24px;
                -webkit-font-smoothing: antialiased;
            }
            h1 { font-size: 28px; font-weight: 700; margin: 24px 0 16px; padding-bottom: 8px; border-bottom: 1px solid \(hrColor); }
            h2 { font-size: 22px; font-weight: 700; margin: 20px 0 12px; padding-bottom: 6px; border-bottom: 1px solid \(hrColor); }
            h3 { font-size: 18px; font-weight: 600; margin: 16px 0 8px; }
            h4 { font-size: 16px; font-weight: 600; margin: 12px 0 6px; }
            h5 { font-size: 14px; font-weight: 500; margin: 10px 0 4px; }
            h6 { font-size: 13px; font-weight: 500; margin: 8px 0 4px; opacity: 0.7; }
            p { margin: 0 0 12px; }
            a { color: \(linkColor); text-decoration: none; }
            a:hover { text-decoration: underline; }
            code {
                font-family: "SF Mono", Menlo, monospace;
                font-size: 12px;
                background: \(codeBg);
                border: 1px solid \(codeBorder);
                border-radius: 4px;
                padding: 1px 5px;
            }
            pre {
                background: \(codeBg);
                border: 1px solid \(codeBorder);
                border-radius: 6px;
                padding: 12px 16px;
                margin: 8px 0 12px;
                overflow-x: auto;
            }
            pre code {
                background: none;
                border: none;
                padding: 0;
                font-size: 12px;
            }
            blockquote {
                border-left: 3px solid \(blockquoteBorder);
                padding-left: 16px;
                margin: 8px 0 12px;
                color: \(blockquoteColor);
            }
            ul, ol { margin: 4px 0 12px; padding-left: 24px; }
            li { margin-bottom: 4px; }
            li > ul, li > ol { margin: 4px 0 0; }
            table {
                border-collapse: collapse;
                margin: 8px 0 12px;
                width: auto;
            }
            th, td {
                border: 1px solid \(tableBorder);
                padding: 6px 12px;
                text-align: left;
            }
            th { font-weight: 600; }
            hr { border: none; border-top: 1px solid \(hrColor); margin: 16px 0; }
            img { max-width: 100%; height: auto; }
            input[type="checkbox"] { margin-right: 6px; }
            /* Find highlight styles are injected by BrowserFindJavaScript */
        </style>
        <script>
        \(markedJsSource())
        </script>
        </head>
        <body>
        <div id="content"></div>
        <template id="raw-md">\(base64Content)</template>
        <script>
            const raw = document.getElementById('raw-md').textContent;
            const bytes = Uint8Array.from(atob(raw), c => c.charCodeAt(0));
            const content = new TextDecoder('utf-8').decode(bytes);
            // Disable raw HTML pass-through to prevent XSS from markdown content
            // (e.g. <img onerror="alert(1)"> or <svg onload=...>).
            marked.use({ renderer: { html(token) { return token.raw.replace(/</g, '&lt;').replace(/>/g, '&gt;'); } } });
            document.getElementById('content').innerHTML = marked.parse(content);
        </script>
        </body>
        </html>
        """
    }

    /// Returns the marked.js library source. Loaded from bundle resources.
    private static func markedJsSource() -> String {
        guard let url = Bundle.main.url(forResource: "marked.min", withExtension: "js"),
              let source = try? String(contentsOf: url) else {
            // Fallback: render as plain text with line breaks
            return """
            const marked = { parse: (text) => '<pre>' + text.replace(/&/g,'&amp;').replace(/</g,'&lt;') + '</pre>' };
            """
        }
        return source
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var searchState: MarkdownSearchState?
        var panelId: UUID?
        var lastContent: String?
        var lastColorScheme: ColorScheme?
        private var needleCancellable: AnyCancellable?
        private var findNextObserver: Any?
        private var findPreviousObserver: Any?
        private var isPageLoaded = false

        override init() {
            super.init()
            findNextObserver = NotificationCenter.default.addObserver(
                forName: .markdownFindNext, object: nil, queue: .main
            ) { [weak self] notification in
                guard let self,
                      let notifiedId = notification.object as? UUID,
                      notifiedId == self.panelId else { return }
                self.navigateNext()
            }
            findPreviousObserver = NotificationCenter.default.addObserver(
                forName: .markdownFindPrevious, object: nil, queue: .main
            ) { [weak self] notification in
                guard let self,
                      let notifiedId = notification.object as? UUID,
                      notifiedId == self.panelId else { return }
                self.navigatePrevious()
            }
        }

        deinit {
            if let findNextObserver { NotificationCenter.default.removeObserver(findNextObserver) }
            if let findPreviousObserver { NotificationCenter.default.removeObserver(findPreviousObserver) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true
            // Set up needle observation for find-in-page
            setupNeedleObserver()
            // If there's already a needle, search immediately
            if let needle = searchState?.needle, !needle.isEmpty {
                performSearch(needle: needle)
            }
        }

        func setupNeedleObserver() {
            needleCancellable?.cancel()
            guard let searchState = searchState else { return }
            needleCancellable = searchState.$needle
                .removeDuplicates()
                .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
                .sink { [weak self] needle in
                    self?.performSearch(needle: needle)
                }
        }

        private func performSearch(needle: String) {
            guard isPageLoaded, let webView = webView else { return }

            if needle.isEmpty {
                webView.evaluateJavaScript(BrowserFindJavaScript.clearScript()) { _, _ in }
                DispatchQueue.main.async { [weak self] in
                    self?.searchState?.total = 0
                    self?.searchState?.selected = nil
                }
                return
            }

            let js = BrowserFindJavaScript.searchScript(query: needle)
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                self.updateFromResult(json)
            }
        }

        func navigateNext() {
            guard isPageLoaded, let webView = webView else { return }
            webView.evaluateJavaScript(BrowserFindJavaScript.nextScript()) { [weak self] result, _ in
                guard let self, let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                self.updateFromResult(json)
            }
        }

        func navigatePrevious() {
            guard isPageLoaded, let webView = webView else { return }
            webView.evaluateJavaScript(BrowserFindJavaScript.previousScript()) { [weak self] result, _ in
                guard let self, let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                self.updateFromResult(json)
            }
        }

        /// Updates the search state from a parsed JSON result dictionary.
        /// Must be called on any thread — dispatches to main internally.
        private func updateFromResult(_ json: [String: Any]) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let total = json["total"] as? Int ?? 0
                self.searchState?.total = UInt(total)
                self.searchState?.selected = total > 0 ? UInt(json["current"] as? Int ?? 0) : nil
            }
        }

        // Open links in the default browser, not inside the markdown viewer
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
