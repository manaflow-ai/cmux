import AppKit
import CmuxAppKitSupportUI
import SwiftUI
import WebKit

struct MarkdownWebRenderer: NSViewRepresentable {
    let markdown: String
    let theme: MarkdownWebTheme
    let backgroundColor: NSColor
    let panelId: UUID
    let workspaceId: UUID
    let filePath: String
    /// Body font size in points, applied as `pageZoom` and to shell-managed SVG zoom.
    let fontSize: Double
    /// Body prose font-family name (empty = System). Applied as an inline
    /// `font-family` on the content.
    let fontFamily: String
    /// Maximum content column width, in CSS pixels.
    let maxContentWidth: Double
    let session: MarkdownRendererSession
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        session.coordinator(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
    }

    func makeNSView(context: Context) -> WKWebView {
        if let webView = context.coordinator.webView {
            if webView.superview != nil {
                webView.removeFromSuperview()
            }
            webView.onPointerDown = onRequestPanelFocus
            webView.onLeaveWindow = { [weak coordinator = context.coordinator] in
                coordinator?.handleViewLeftWindow()
            }
            webView.onReenterWindow = { [weak coordinator = context.coordinator] in
                coordinator?.handleViewReenteredWindow()
            }
            webView.navigationDelegate = context.coordinator
            webView.uiDelegate = context.coordinator
            webView.applyBackgroundFill(backgroundColor)
            webView.applyForcedAppearance(isDark: theme.isDark)
            context.coordinator.setFontSize(fontSize)
            context.coordinator.setFontFamily(fontFamily)
            context.coordinator.setMaxContentWidth(maxContentWidth)
            return webView
        }

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        // Bridge: JS posts to `cmuxLib` to request lazy-loaded libraries
        // (mermaid / vega-lite). Swift fetches the bundled source from the
        // app bundle and injects it via evaluateJavaScript.
        config.userContentController.add(WeakMarkdownScriptMessageHandler(context.coordinator), name: "cmuxLib")
        config.setURLSchemeHandler(
            context.coordinator.imageSchemeHandler,
            forURLScheme: MarkdownImageSchemeHandler.localImageURLScheme
        )
        config.setURLSchemeHandler(
            context.coordinator.imageSchemeHandler,
            forURLScheme: MarkdownImageSchemeHandler.remoteImageURLScheme
        )
        let webView = MarkdownWebView(frame: .zero, configuration: config)
        webView.onPointerDown = onRequestPanelFocus
        webView.onLeaveWindow = { [weak coordinator = context.coordinator] in
            coordinator?.handleViewLeftWindow()
        }
        webView.onReenterWindow = { [weak coordinator = context.coordinator] in
            coordinator?.handleViewReenteredWindow()
        }
        webView.setValue(false, forKey: "drawsBackground")
        webView.applyBackgroundFill(backgroundColor)
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        if #available(macOS 13.3, *) {
#if DEBUG
            webView.isInspectable = true
#else
            webView.isInspectable = false
#endif
        }
        webView.applyForcedAppearance(isDark: theme.isDark)

        context.coordinator.webView = webView
        context.coordinator.setFontSize(fontSize)
        context.coordinator.setFontFamily(fontFamily)
        context.coordinator.setMaxContentWidth(maxContentWidth)
        context.coordinator.loadShell(theme: theme, initialMarkdown: markdown)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Re-bind panel metadata in case SwiftUI recreated the wrapper while
        // the panel-owned renderer session kept the same coordinator.
        context.coordinator.bind(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
        (nsView as? MarkdownWebView)?.onPointerDown = onRequestPanelFocus
        nsView.applyBackgroundFill(backgroundColor)
        nsView.applyForcedAppearance(isDark: theme.isDark)
        context.coordinator.setFontSize(fontSize)
        context.coordinator.setFontFamily(fontFamily)
        context.coordinator.setMaxContentWidth(maxContentWidth)
        context.coordinator.update(markdown: markdown, theme: theme)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        if let retainedWebView = coordinator.webView, retainedWebView === nsView {
            return
        }
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        (nsView as? MarkdownWebView)?.onPointerDown = nil
        (nsView as? MarkdownWebView)?.onLeaveWindow = nil
        (nsView as? MarkdownWebView)?.onReenterWindow = nil
        coordinator.cancelImageLoads()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
        var webView: MarkdownWebView?
        var filePath: String = "" {
            didSet { imageSchemeHandler.filePath = filePath }
        }
        /// Routes clicked links and JS-bridge file-open requests to the right
        /// cmux surface (markdown tab, in-app browser, or system handler). Kept
        /// in sync with the panel binding in `bind(panelId:workspaceId:filePath:)`.
        private var linkRouter = MarkdownLinkRouter(surfaceRouting: AppDelegateMarkdownPanelSurfaceRouting())
        /// Owns the `WKURLSchemeHandler` responsibility for the custom image
        /// schemes. Registered on the web view configuration in place of the
        /// coordinator; kept in sync with `filePath` via the property observer.
        let imageSchemeHandler = MarkdownImageSchemeHandler()
        private var pendingMarkdown: String = ""
        private var pendingTheme: MarkdownWebTheme = .resolve(backgroundColor: GhosttyBackgroundTheme.currentColor())
        private var lastMarkdown: String? = nil
        private var lastTheme: MarkdownWebTheme? = nil
        private var lastFontFamily: String = ""
        private var lastFontSize: Double = MarkdownFontSizeSettings.defaultPointSize
        private var lastMaxContentWidth: Double = MarkdownMaxWidthSettings.defaultCSSPixels
        private var isLoaded = false
        private var isShellLoading = false
        /// WebContent crash-recovery + detach/reattach health budget. The
        /// `loadShell` effect and `WKWebView` identity guard stay here; the
        /// pure budget decisions live on the policy.
        private var recoveryPolicy = MarkdownWebRecoveryPolicy()

#if DEBUG
        var isShellLoadingForTesting: Bool {
            isShellLoading
        }

        var webContentProcessRecoveryAttemptsForTesting: Int {
            recoveryPolicy.attempts
        }
#endif

        func bind(panelId: UUID, workspaceId: UUID, filePath: String) {
            self.filePath = filePath
            linkRouter.bind(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
        }

        /// Records the desired body font size and applies it as `pageZoom`.
        /// Stored so it can be re-applied after the shell reloads (e.g. after a
        /// web-content-process crash recovery).
        func setFontSize(_ pointSize: Double) {
            lastFontSize = pointSize
            applyFontSize()
        }

        private func applyFontSize(forceShellSync: Bool = false) {
            guard let webView else { return }
            let zoom = MarkdownFontSizeSettings.pageZoom(forPointSize: lastFontSize)
            let shouldSyncShell = forceShellSync || abs(webView.pageZoom - zoom) > 0.0001
            if abs(webView.pageZoom - zoom) > 0.0001 { webView.pageZoom = zoom }
            if shouldSyncShell { webView.evaluateJavaScript(MarkdownRenderScript.setMarkdownZoom(zoom).source, completionHandler: nil) }
        }

        /// Records the desired body prose font and applies it as an inline
        /// `font-family` on the content element. Unlike `pageZoom`, this DOM
        /// style is lost when the shell reloads, so it must be re-applied in
        /// `didFinish`.
        func setFontFamily(_ family: String) {
            lastFontFamily = family
            applyFontFamily()
        }

        private func applyFontFamily() {
            guard let webView else { return }
            let css = MarkdownFontFamily.cssValue(for: lastFontFamily) ?? ""
            webView.evaluateJavaScript(MarkdownRenderScript.setContentFontFamily(css: css).source, completionHandler: nil)
        }

        /// Records the desired content column max width. This DOM style is lost
        /// when the shell reloads, so it is re-applied in `didFinish`.
        func setMaxContentWidth(_ pixels: Double) {
            lastMaxContentWidth = MarkdownMaxWidthSettings.clamp(pixels)
            applyMaxContentWidth()
        }

        private func applyMaxContentWidth() {
            guard let webView else { return }
            let width = Int(MarkdownMaxWidthSettings.clamp(lastMaxContentWidth).rounded())
            webView.evaluateJavaScript(MarkdownRenderScript.setContentMaxWidth(width).source, completionHandler: nil)
        }

        func close() {
            if let webView {
                webView.stopLoading()
                webView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
                webView.onPointerDown = nil
                webView.onLeaveWindow = nil
                webView.onReenterWindow = nil
            }
            self.webView = nil
            isLoaded = false
            isShellLoading = false
            recoveryPolicy.reset()
            cancelImageLoads()
            libraryInjector.reset()
        }

        func loadShell(theme: MarkdownWebTheme, initialMarkdown: String) {
            pendingMarkdown = initialMarkdown
            pendingTheme = theme
            lastTheme = theme
            libraryInjector.reset()
            isLoaded = false
            isShellLoading = true
            let html = MarkdownViewerAssets.shared.shellHTML(isDark: theme.isDark)
            let baseURL = URL(fileURLWithPath: filePath)
#if DEBUG
            NSLog("MarkdownPanel.loadShell filePath=\(filePath) baseURL=\(baseURL.absoluteString) htmlBytes=\(html.utf8.count)")
#endif
            webView?.loadHTMLString(html, baseURL: baseURL)
        }

        func update(markdown: String, theme: MarkdownWebTheme) {
            let themeChanged = lastTheme != theme
            let contentChanged = lastMarkdown != markdown
            let shellNeedsReload = !isLoaded && !isShellLoading
            guard themeChanged || contentChanged || shellNeedsReload else { return }

            pendingMarkdown = markdown
            pendingTheme = theme

            if themeChanged {
                lastTheme = theme
                // The WKWebView's NSAppearance change (handled in the
                // representable's update path) flips `prefers-color-scheme`
                // automatically. We still nudge the page so highlight.js
                // swaps stylesheets even if the matchMedia listener is
                // slow to fire.
                if isLoaded {
                    applyTheme(theme)
                    if !contentChanged {
                        pushMarkdown(lastMarkdown ?? pendingMarkdown)
                    }
                }
            }

            if contentChanged {
                recoveryPolicy.resetBudget()
                lastMarkdown = markdown
                if isLoaded {
                    pushMarkdown(markdown)
                } else if shellNeedsReload {
                    loadShell(theme: theme, initialMarkdown: markdown)
                }
            } else if shellNeedsReload {
                if recoveryPolicy.hasBudgetRemaining {
                    loadShell(theme: theme, initialMarkdown: markdown)
                }
            }
        }

        func renderedHTML(markdown: String? = nil) async -> String? {
            guard isLoaded else { return nil }
            if let markdown {
                guard await renderMarkdownForExport(markdown) else { return nil }
            }
            // We export an explicit "rendered HTML" getter from JS so callers
            // get the *content* div only, without the shell <style>/<script>.
            return await evaluateString("window.__cmuxRenderedHTML && window.__cmuxRenderedHTML()")
        }

        func renderedText() async -> String? {
            guard isLoaded else { return nil }
            return await evaluateString("window.__cmuxRenderedText && window.__cmuxRenderedText()")
        }

        private func evaluateString(_ script: String) async -> String? {
            guard let webView else { return nil }
            do {
                return try await webView.evaluateJavaScript(script) as? String
            } catch {
                return nil
            }
        }

        private func applyTheme(_ theme: MarkdownWebTheme) {
            guard let webView else { return }
            guard let script = MarkdownRenderScript.applyThemeVariables(theme.cssVariables) else { return }
            webView.evaluateJavaScript(script.source, completionHandler: nil)
        }

        // MARK: Bridge

        private func pushMarkdown(_ markdown: String) {
            guard let webView else { return }
#if DEBUG
            NSLog("MarkdownPanel.pushMarkdown bytes=\(markdown.utf8.count)")
#endif
            guard let js = MarkdownRenderScript.renderMarkdown(markdown)?.source else { return }
            webView.evaluateJavaScript(js) { _, error in
#if DEBUG
                if let error {
                    NSLog("MarkdownPanel: pushMarkdown evaluateJavaScript failed: \(error)")
                }
#endif
            }
        }

        private func renderMarkdownForExport(_ markdown: String) async -> Bool {
            guard let webView, isLoaded else { return false }
            guard let js = MarkdownRenderScript.renderMarkdown(markdown)?.source else { return false }
            do {
                _ = try await webView.evaluateJavaScript(js)
                lastMarkdown = markdown
                pendingMarkdown = markdown
                return true
            } catch {
#if DEBUG
                NSLog("MarkdownPanel: renderMarkdownForExport evaluateJavaScript failed: \(error)")
#endif
                return false
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "cmuxLib",
                  let body = message.body as? [String: Any] else { return }
            if let lib = body["lib"] as? String {
                handleLibRequest(lib)
                return
            }
            if let action = body["action"] as? String {
#if DEBUG
                NSLog("MarkdownPanel.bridge action=\(action) body=\(body)")
#endif
                switch action {
                case "resolveMarkdownFile":
                    guard let requestId = body["requestId"] as? String,
                          let rawPath = body["path"] as? String else { return }
                    linkRouter.resolveMarkdownFile(rawPath, requestId: requestId, on: webView)
                case "openMarkdownFile":
                    guard let rawPath = body["path"] as? String else { return }
                    if let resolved = linkRouter.resolvedMarkdownFilePath(rawPath) {
                        linkRouter.openMarkdownFile(resolved)
                    }
                default:
                    break
                }
            }
        }

        /// Owns the lazy-library injection bookkeeping (which JS libs have been
        /// requested for the current WebView) and the injection itself. Reset
        /// whenever the shell reloads.
        private let libraryInjector = MarkdownLibraryInjector()

        // MARK: WKURLSchemeHandler
        //
        // The image/URL-scheme engine lives in `MarkdownImageSchemeHandler`,
        // which is the object actually registered on the web view
        // configuration. These methods forward to it so existing call sites
        // (and unit tests that drive the scheme handler through the
        // coordinator) keep working unchanged.

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            imageSchemeHandler.webView(webView, start: urlSchemeTask)
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            imageSchemeHandler.webView(webView, stop: urlSchemeTask)
        }

        func cancelImageLoads() {
            imageSchemeHandler.cancelImageLoads()
        }

        func cancelLocalImageLoads() {
            imageSchemeHandler.cancelLocalImageLoads()
        }

        private func handleLibRequest(_ lib: String) {
            guard let webView else { return }
            libraryInjector.inject(lib, into: webView)
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
#if DEBUG
            NSLog("MarkdownPanel.webView.didFinish")
#endif
            isShellLoading = false
            isLoaded = true
            // pageZoom is a WKWebView-level property that survives loadHTMLString,
            // but re-apply defensively after a shell reload so a crash-recovery
            // path can never drop the configured zoom.
            applyFontSize(forceShellSync: true)
            // font-family is a DOM inline style on a freshly-created #content,
            // so it MUST be re-applied after every shell (re)load.
            applyFontFamily()
            applyMaxContentWidth()
            applyTheme(lastTheme ?? pendingTheme)
            // Replay last known markdown after the shell finishes loading.
            // Keep the recovery budget scoped to the current markdown payload:
            // a payload can crash after shell load during the render push.
            // Content changes reset the budget in `update(markdown:theme:)`.
            let md = lastMarkdown ?? pendingMarkdown
            lastMarkdown = md
            pushMarkdown(md)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleShellNavigationFailure(for: webView, error: error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            handleShellNavigationFailure(for: webView, error: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let currentWebView = self.webView, currentWebView === webView else { return }
#if DEBUG
            NSLog("MarkdownPanel.webView.webContentProcessDidTerminate")
#endif
            isShellLoading = false
            guard recoveryPolicy.consumeBudget() else {
                isLoaded = false
                libraryInjector.reset()
                return
            }
            loadShell(
                theme: lastTheme ?? pendingTheme,
                initialMarkdown: lastMarkdown ?? pendingMarkdown
            )
        }

        /// Called when the host `MarkdownWebView` re-enters a window after
        /// having been detached (e.g. a pane drag re-parents the hosting
        /// views via `removeFromSuperview` → `addSubview`). While detached
        /// from the window WebKit can reclaim the WebContent process,
        /// leaving the panel permanently blank with no user-facing reload.
        /// Records, at the moment the host view leaves its window, whether the
        /// document was healthy. The blank state seen after re-entry is only
        /// treated as a detach artifact (and recovered with a fresh budget) if
        /// the shell was loaded when it was detached.
        func handleViewLeftWindow() {
            recoveryPolicy.recordDetachHealth(shellIsLoaded: isLoaded)
        }

        func handleViewReenteredWindow() {
            // A still-loaded shell — alive but merely unpainted — is left
            // intact; the host view's repaint nudge handles that case.
            guard !isLoaded else { return }
            // Recover only when the document was healthy before the detach, so
            // a payload that exhausted its crash-recovery budget while attached
            // (a crash loop) is not granted a fresh budget by pane reparenting.
            // A reload kicked off while detached can stall (no didFinish until
            // the view is back in a window), so the policy restores the
            // recovery budget on a deliberate reattach and we reload
            // unconditionally — even mid-load — so the document repaints
            // instead of staying permanently blank.
            guard recoveryPolicy.consumeDetachRecovery() else { return }
            loadShell(
                theme: lastTheme ?? pendingTheme,
                initialMarkdown: lastMarkdown ?? pendingMarkdown
            )
        }

        private func handleShellNavigationFailure(for webView: WKWebView, error: Error) {
            guard let currentWebView = self.webView, currentWebView === webView, isShellLoading else { return }
#if DEBUG
            NSLog("MarkdownPanel.webView.navigationFailed error=\(error)")
#endif
            isShellLoading = false
            isLoaded = false
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // The first load (loadHTMLString) has navigationType = .other —
            // allow it. Anything the user clicks (links, anchors, ...) we
            // route through the cmux tab/browser machinery.
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
#if DEBUG
                NSLog("MarkdownPanel.nav linkActivated url=\(url.absoluteString)")
#endif
                if MarkdownPanelFileLinkResolver.isInPageFragment(url, relativeToMarkdownFile: filePath) {
                    // Same-document fragment navigation (heading anchors)
                    // scrolls the panel — keep it native.
                    decisionHandler(.allow)
                    return
                }
                linkRouter.handleExternalLink(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // target=_blank / window.open from inside the rendered markdown.
            if let url = navigationAction.request.url {
                linkRouter.handleExternalLink(url)
            }
            return nil
        }

    }
}
