import AppKit
import WebKit

/// Owns the markdown panel's Monaco edit webview: page generation + loading
/// over the per-panel custom scheme, the save/mirror message bridge, focus,
/// and the JS host hooks (content pull, disk adoption, needle reveal, word
/// wrap). Session-owned (see ``MarkdownEditorSession``) so split/tab layout
/// churn never recreates the webview, which would drop the buffer and its
/// undo stack.
@MainActor
final class MarkdownEditorRendererCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: MarkdownEditorWebView?
    private weak var panel: MarkdownPanel?
    private let token = UUID().uuidString.lowercased()
    private let keyEquivalentRouter = EditorKeyEquivalentRouter()
    private var schemeHandler: MarkdownEditorSchemeHandler?
    private var isLoaded = false
    private var isLoading = false
    private var pendingNeedle: String?
    private var wantsFocusWhenLoaded = false
    private var lastWordWrap: Bool?
    private var loadedAppearanceSignature: String?
    private var lastAppearance: PanelAppearance?
    private var recoveryAttempts = 0
    private let maxRecoveryAttempts = 2

    func bind(panel: MarkdownPanel) {
        self.panel = panel
    }

    func ensureWebView(onPointerDown: @escaping () -> Void) -> MarkdownEditorWebView {
        if let webView {
            webView.onPointerDown = onPointerDown
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        let schemeHandler = MarkdownEditorSchemeHandler(token: token)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: MarkdownEditorSchemeHandler.scheme)
        configuration.userContentController.addScriptMessageHandler(
            MarkdownEditorMessageHandler(
                expectedOriginToken: token,
                onContentMirrored: { [weak self] dirty, content in
                    guard let content else { return }
                    self?.panel?.applyEditorContentMirror(content, pageIsDirty: dirty)
                },
                onSave: { [weak self] content, expectedSha256, force in
                    guard let panel = self?.panel else {
                        return ["error": ["code": "unauthorized"]]
                    }
                    return await panel.performEditorSave(
                        content: content,
                        expectedSha256: expectedSha256,
                        force: force
                    )
                }
            ),
            contentWorld: .page,
            name: MarkdownEditorMessageHandler.handlerName
        )
        self.schemeHandler = schemeHandler

        let webView = MarkdownEditorWebView(frame: .zero, configuration: configuration)
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
        webView.onEditorKeyEquivalent = { [weak self] event in
            guard let self, let webView = self.webView else { return false }
            // The page is always an editor here, so the save shortcut is
            // consumed even when the buffer is clean (matching the previous
            // NSTextView editor); the page's save controller no-ops.
            return self.keyEquivalentRouter.handle(
                event: event,
                webView: webView,
                isBufferDirty: true,
                isEditorActive: true
            )
        }
        self.webView = webView
        return webView
    }

    /// Loads the editor page on first presentation and regenerates it when
    /// the panel theme changes; otherwise just applies live option updates.
    func presentEditor(appearance: PanelAppearance, wordWrap: Bool) {
        guard webView != nil, let panel else { return }
        lastAppearance = appearance
        let signature = Self.appearanceSignature(appearance)
        if !isLoaded && !isLoading {
            loadPage(content: panel.textContent, appearance: appearance, wordWrap: wordWrap)
            return
        }
        if isLoaded, signature != loadedAppearanceSignature {
            // Theme changed under a live editor. Pull the buffer first so
            // unsaved edits survive the regenerated page (the undo stack does
            // not; theme switches are rare enough that a faithful recolor
            // wins over preserving undo across them).
            pullContent { [weak self] content in
                guard let self, let panel = self.panel else { return }
                if let content {
                    panel.updateTextContent(content)
                }
                self.loadPage(content: panel.textContent, appearance: appearance, wordWrap: wordWrap)
            }
            return
        }
        applyWordWrap(wordWrap)
    }

    private func loadPage(content: String, appearance: PanelAppearance, wordWrap: Bool) {
        guard let webView, let panel, let schemeHandler, let pageURL = schemeHandler.pageURL else { return }
        let html: String
        do {
            html = try MarkdownEditorPage.html(
                filePath: panel.filePath,
                content: content,
                readOnly: !FileManager.default.isWritableFile(atPath: panel.filePath),
                contentSha256: panel.editorBaselineSha256 ?? "",
                // Pages are always seeded from panel.textContent, so the
                // panel's dirty flag says whether that seed already diverges
                // from disk (theme-change / crash-recovery reloads of an
                // unsaved buffer must boot dirty).
                initialDirty: panel.isDirty,
                wordWrap: wordWrap,
                appearance: appearance
            )
        } catch {
            return
        }
        schemeHandler.updatePage(html: html)
        loadedAppearanceSignature = Self.appearanceSignature(appearance)
        lastWordWrap = wordWrap
        isLoaded = false
        isLoading = true
        applyWebViewAppearance(appearance, to: webView)
        webView.load(URLRequest(url: pageURL))
    }

    // MARK: - Host hooks

    /// Reads the live Monaco buffer (used before switching to preview so the
    /// rendered markdown shows the very latest unsaved edits).
    func pullContent(_ completion: @escaping (String?) -> Void) {
        guard let webView, isLoaded else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript(
            "typeof window.__cmuxEditorGetContent === 'function' ? window.__cmuxEditorGetContent() : null"
        ) { result, _ in
            completion(result as? String)
        }
    }

    /// Pushes on-disk bytes into the page after a clean-buffer disk change or
    /// an explicit revert. The page skips identical content so a save echo
    /// from the panel's own write never resets the undo stack.
    func adoptDiskContent(_ content: String, sha256: String?) {
        callHostHook("__cmuxEditorAdoptDiskContent", arguments: [content, sha256 ?? NSNull()])
    }

    /// Selects and reveals the first match of `needle` (global search jump).
    /// Queued until the page finishes loading when needed.
    func revealNeedle(_ needle: String) {
        guard isLoaded else {
            pendingNeedle = needle
            return
        }
        callHostHook("__cmuxEditorRevealNeedle", arguments: [needle])
    }

    /// Asks the page's save controller to save (same path as the save
    /// shortcut), so status chrome and conflict handling stay in the page.
    func requestSave() {
        callHostHook("__cmuxEditorRequestSave", arguments: [])
    }

    private func applyWordWrap(_ wordWrap: Bool) {
        guard lastWordWrap != wordWrap, isLoaded else { return }
        lastWordWrap = wordWrap
        callHostHook("__cmuxEditorSetWordWrap", arguments: [wordWrap])
    }

    /// Invokes a page host hook, or parks the call in
    /// `window.__cmuxEditorPendingCalls` when the hook is not installed yet:
    /// WebKit's didFinish fires well before the surface finishes booting
    /// (module imports, Monaco setup), and the page replays parked calls in
    /// order once its hooks exist.
    private func callHostHook(_ function: String, arguments: [Any]) {
        guard let webView, isLoaded else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: arguments),
              let argumentsLiteral = String(data: data, encoding: .utf8),
              let functionLiteral = try? JSONSerialization.data(withJSONObject: [function]),
              let functionName = String(data: functionLiteral, encoding: .utf8) else {
            return
        }
        let script = """
        (function(name, args) {
          var fn = window[name];
          if (typeof fn === 'function') { fn.apply(null, args); return; }
          (window.__cmuxEditorPendingCalls = window.__cmuxEditorPendingCalls || []).push([name, args]);
        })(\(functionName)[0], \(argumentsLiteral));
        """
        webView.evaluateJavaScript(script)
    }

    func focus() {
        guard let webView, isLoaded else {
            wantsFocusWhenLoaded = true
            return
        }
        guard let window = webView.window else {
            wantsFocusWhenLoaded = true
            return
        }
        // Avoid first-responder churn when SwiftUI re-runs updates while the
        // editor already holds focus (WKWebView's actual responder is an
        // inner content view) — and never re-grab Monaco's caret then, since
        // in-page focus may legitimately be elsewhere (the find widget).
        guard !Self.responderChainContains(window.firstResponder, target: webView) else { return }
        window.makeFirstResponder(webView)
        // First-responder status alone gives Monaco no caret; focus the
        // editor itself so typing lands in the buffer immediately (parked by
        // the page until its hooks exist during boot).
        callHostHook("__cmuxEditorFocus", arguments: [])
    }

    func close() {
        if let webView {
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: MarkdownEditorMessageHandler.handlerName,
                contentWorld: .page
            )
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.onPointerDown = nil
            webView.onEditorKeyEquivalent = nil
            webView.removeFromSuperview()
        }
        webView = nil
        schemeHandler = nil
        isLoaded = false
        isLoading = false
        pendingNeedle = nil
        wantsFocusWhenLoaded = false
        loadedAppearanceSignature = nil
        lastWordWrap = nil
        recoveryAttempts = 0
    }

    // MARK: - Appearance

    /// One hex-signature per theme so a live cmux theme switch regenerates
    /// the page (Monaco theme colors are baked into the page config).
    static func appearanceSignature(_ appearance: PanelAppearance) -> String {
        appearance.backgroundColor.markdownOpaqueSRGB.hexString()
            + "/"
            + appearance.foregroundColor.markdownOpaqueSRGB.hexString()
    }

    /// Forces the webview's `NSAppearance` to the panel theme so the page's
    /// `prefers-color-scheme` matches the colors baked into its config
    /// (mirrors `MarkdownWebRenderer.applyAppearance`).
    private func applyWebViewAppearance(_ appearance: PanelAppearance, to webView: WKWebView) {
        let isDark = !appearance.backgroundColor.markdownOpaqueSRGB.isLightColor
        let target = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if webView.appearance !== target {
            webView.appearance = target
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        isLoaded = true
        recoveryAttempts = 0
        // Sync any disk content the panel adopted while the page was loading
        // (the page parks the call until its hooks exist and skips identical
        // content, so this is a no-op on the common path).
        if let panel {
            adoptDiskContent(panel.textContent, sha256: panel.editorBaselineSha256)
        }
        if let needle = pendingNeedle {
            pendingNeedle = nil
            revealNeedle(needle)
        }
        if wantsFocusWhenLoaded {
            wantsFocusWhenLoaded = false
            focus()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let currentWebView = self.webView, currentWebView === webView else { return }
        isLoading = false
        isLoaded = false
        guard recoveryAttempts < maxRecoveryAttempts,
              let panel,
              let appearance = lastAppearance else { return }
        recoveryAttempts += 1
        // The panel's mirrored textContent is the best surviving copy of the
        // buffer (the page mirrors edits as they happen), so recovery loses
        // at most the last debounce interval of typing.
        loadPage(
            content: panel.textContent,
            appearance: appearance,
            wordWrap: lastWordWrap ?? FilePreviewWordWrapSettings.isEnabled()
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // The editor page is the only document this webview may show.
        if let url = navigationAction.request.url,
           url.scheme == MarkdownEditorSchemeHandler.scheme,
           url.host == token {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    // MARK: - Helpers

    private static func responderChainContains(_ responder: NSResponder?, target: NSResponder) -> Bool {
        var current = responder
        while let item = current {
            if item === target {
                return true
            }
            current = item.nextResponder
        }
        return false
    }
}
