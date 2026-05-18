import AppKit
import SwiftUI
import WebKit

struct MarkdownWebTheme: Equatable {
    let isDark: Bool
    let background: String
    let mutedBackground: String
    let neutralMutedBackground: String
    let border: String
    let mutedBorder: String

    static func resolve(backgroundColor: NSColor) -> MarkdownWebTheme {
        let base = backgroundColor.markdownOpaqueSRGB
        let isDark = !base.isLightColor
        let overlayColor: NSColor = isDark ? .white : .black
        let muted = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.09 : 1.06,
            of: overlayColor
        )
        let neutralMuted = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.35 : 1.20,
            of: overlayColor
        )
        let border = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.92 : 1.43,
            of: overlayColor
        )
        return MarkdownWebTheme(
            isDark: isDark,
            background: "transparent",
            mutedBackground: muted.markdownCSSColor,
            neutralMutedBackground: neutralMuted.markdownCSSColor,
            border: border.markdownCSSColor,
            mutedBorder: border.withAlphaComponent(border.alphaComponent * 0.70).markdownCSSColor
        )
    }
}

struct MarkdownWebRenderer: NSViewRepresentable {
    let markdown: String
    let theme: MarkdownWebTheme
    let backgroundColor: NSColor
    let panelId: UUID
    let workspaceId: UUID
    let filePath: String
    let handle: MarkdownWebRendererHandle
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.panelId = panelId
        c.workspaceId = workspaceId
        c.filePath = filePath
        handle.coordinator = c
        return c
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        // Bridge: JS posts to `cmuxLib` to request lazy-loaded libraries
        // (mermaid / vega-lite). Swift fetches the bundled source from the
        // app bundle and injects it via evaluateJavaScript.
        config.userContentController.add(context.coordinator, name: "cmuxLib")
        let webView = MarkdownWebView(frame: .zero, configuration: config)
        webView.onPointerDown = onRequestPanelFocus
        webView.setValue(false, forKey: "drawsBackground")
        applyBackground(to: webView)
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
        applyAppearance(to: webView, isDark: theme.isDark)

        context.coordinator.webView = webView
        context.coordinator.loadShell(theme: theme, initialMarkdown: markdown)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Re-bind the handle in case SwiftUI recreated the representable
        // wrapper while keeping the same NSView around.
        handle.coordinator = context.coordinator
        context.coordinator.panelId = panelId
        context.coordinator.workspaceId = workspaceId
        context.coordinator.filePath = filePath
        (nsView as? MarkdownWebView)?.onPointerDown = onRequestPanelFocus
        applyBackground(to: nsView)
        applyAppearance(to: nsView, isDark: theme.isDark)
        context.coordinator.update(markdown: markdown, theme: theme)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        (nsView as? MarkdownWebView)?.onPointerDown = nil
        if coordinator.webView === nsView {
            coordinator.webView = nil
        }
    }

    /// WebKit's `prefers-color-scheme` media query reflects the WKWebView's
    /// effective NSAppearance. Forcing it here lets us decouple the markdown
    /// panel from the system appearance and follow the cmux color scheme.
    private func applyAppearance(to webView: WKWebView, isDark: Bool) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if webView.appearance !== appearance {
            webView.appearance = appearance
        }
    }

    private func applyBackground(to webView: WKWebView) {
        webView.underPageBackgroundColor = backgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var panelId: UUID = UUID()
        var workspaceId: UUID = UUID()
        var filePath: String = ""
        private var pendingMarkdown: String = ""
        private var pendingTheme: MarkdownWebTheme = .resolve(backgroundColor: GhosttyBackgroundTheme.currentColor())
        private var lastMarkdown: String? = nil
        private var lastTheme: MarkdownWebTheme? = nil
        private var isLoaded = false

        func loadShell(theme: MarkdownWebTheme, initialMarkdown: String) {
            pendingMarkdown = initialMarkdown
            pendingTheme = theme
            lastTheme = theme
            requestedLibs.removeAll()
            isLoaded = false
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
            guard themeChanged || contentChanged else { return }

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
                lastMarkdown = markdown
                if isLoaded {
                    pushMarkdown(markdown)
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
            let payload = [
                "--bgColor-default": theme.background,
                "--bgColor-muted": theme.mutedBackground,
                "--bgColor-neutral-muted": theme.neutralMutedBackground,
                "--borderColor-default": theme.border,
                "--borderColor-muted": theme.mutedBorder,
                "--borderColor-neutral-muted": theme.mutedBorder
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = """
            (function(vars) {
              var content = document.getElementById('content');
              if (!content) { return; }
              Object.keys(vars).forEach(function(name) {
                content.style.setProperty(name, vars[name]);
              });
              content.style.background = 'transparent';
              if (window.__cmuxApplyTheme) { window.__cmuxApplyTheme(); }
            })(\(json));
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // MARK: Bridge

        private func pushMarkdown(_ markdown: String) {
            guard let webView else { return }
#if DEBUG
            NSLog("MarkdownPanel.pushMarkdown bytes=\(markdown.utf8.count)")
#endif
            guard let js = Self.renderMarkdownScript(markdown) else { return }
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
            guard let js = Self.renderMarkdownScript(markdown) else { return false }
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

        private static func renderMarkdownScript(_ markdown: String) -> String? {
            // Send the raw markdown through a JSON literal so we don't have
            // to hand-escape backticks/backslashes/quotes for JS.
            guard let data = try? JSONSerialization.data(withJSONObject: [markdown]),
                  let arrayLiteral = String(data: data, encoding: .utf8) else { return nil }
            return """
            (function(md) {
              if (window.__cmuxRenderMarkdown) {
                window.__cmuxRenderMarkdown(md);
                return;
              }
              var el = document.getElementById('content') || document.body;
              function esc(s) {
                var div = document.createElement('div');
                div.textContent = String(s == null ? '' : s);
                return div.innerHTML;
              }
              el.innerHTML = '<pre style=\"color:#f85149;white-space:pre-wrap\">Markdown renderer failed to initialize. Showing raw source.\\n\\n' + esc(md) + '</pre>';
            })(\(arrayLiteral)[0]);
            """
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
                    resolveMarkdownFile(rawPath, requestId: requestId)
                case "openMarkdownFile":
                    guard let rawPath = body["path"] as? String else { return }
                    if let resolved = resolvedMarkdownFilePath(rawPath) {
                        openMarkdownFile(resolved)
                    }
                default:
                    break
                }
            }
        }

        private var requestedLibs: Set<String> = []

        private func resolveMarkdownFile(_ rawPath: String, requestId: String) {
            guard let webView else { return }
            let resolved = resolvedMarkdownFilePath(rawPath)
#if DEBUG
            NSLog("MarkdownPanel.resolve raw=\(rawPath) resolved=\(resolved ?? "nil")")
#endif
            let payload: [String: Any] = [
                "requestId": requestId,
                "exists": resolved != nil,
                "path": resolved ?? ""
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.__cmuxMarkdownFileResolved && window.__cmuxMarkdownFileResolved(\(json));", completionHandler: nil)
        }

        private func resolvedMarkdownFilePath(_ rawPath: String) -> String? {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard MarkdownPanelFileLinkResolver.isMarkdownPathLike(trimmed) else { return nil }
            return MarkdownPanelFileLinkResolver.resolve(rawPath: trimmed, relativeToMarkdownFile: filePath)
        }

        private func openMarkdownFile(_ path: String) {
#if DEBUG
            NSLog("MarkdownPanel.openMarkdownFile path=\(path)")
#endif
            guard let app = AppDelegate.shared,
                  let location = app.workspaceContainingPanel(
                      panelId: panelId,
                      preferredWorkspaceId: workspaceId
                  ),
                  let paneId = location.workspace.paneId(forPanelId: panelId) else { return }
            _ = location.workspace.newMarkdownSurface(
                inPane: paneId,
                filePath: path,
                focus: true
            )
        }

        private func handleLibRequest(_ lib: String) {
            guard let webView else { return }
            // Load each library at most once per WebView lifetime. State is
            // reset only when the shell is reloaded via loadShell(); theme
            // switches reuse the already-loaded libs.
            if requestedLibs.contains(lib) { return }
            requestedLibs.insert(lib)

            let assets = MarkdownViewerAssets.shared
            let sources: [String]
            switch lib {
            case "mermaid":
                sources = [assets.lazyAsset(name: "mermaid.min", ext: "js")]
            case "vega-lite":
                // Order matters: vega first, then vega-lite, then vega-embed.
                sources = [
                    assets.lazyAsset(name: "vega.min", ext: "js"),
                    assets.lazyAsset(name: "vega-lite.min", ext: "js"),
                    assets.lazyAsset(name: "vega-embed.min", ext: "js"),
                ]
            default:
                return
            }

            // Concatenate the bundled sources into a single evaluateJavaScript
            // call, then notify the page that the lib is ready. Any parse or
            // throw in the bundle surfaces through the completion handler.
            var injection = ""
            for src in sources where !src.isEmpty {
                injection += src
                injection += "\n;"
            }
            // JSON-encode the lib name to safely splice into JS.
            let libLiteral = (try? JSONSerialization.data(withJSONObject: [lib]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            let suffix = "\nwindow.__cmuxLibLoaded && window.__cmuxLibLoaded(\(libLiteral)[0]);"
            webView.evaluateJavaScript(injection + suffix) { [weak self] _, error in
                if let error {
                    // Allow retry on next render if this attempt failed.
                    self?.requestedLibs.remove(lib)
#if DEBUG
                    NSLog("MarkdownPanel: failed to load \(lib): \(error)")
#endif
                }
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
#if DEBUG
            NSLog("MarkdownPanel.webView.didFinish")
#endif
            isLoaded = true
            applyTheme(lastTheme ?? pendingTheme)
            // Replay last known markdown after the shell finishes loading.
            let md = lastMarkdown ?? pendingMarkdown
            lastMarkdown = md
            pushMarkdown(md)
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
                if isInPageFragment(url) {
                    // Same-document fragment navigation (heading anchors)
                    // scrolls the panel — keep it native.
                    decisionHandler(.allow)
                    return
                }
                handleExternalLink(url)
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
                handleExternalLink(url)
            }
            return nil
        }

        // MARK: - Link routing

        /// Route a clicked link to a brand-new cmux browser tab in the same
        /// pane as this markdown panel — mirroring how Browser panels open
        /// child links via `openLinkInNewTab`. Falls back to the system
        /// browser only when the in-app browser is disabled or the panel
        /// can't be located in any workspace.
        private func handleExternalLink(_ url: URL) {
#if DEBUG
            NSLog("MarkdownPanel.handleExternalLink url=\(url.absoluteString)")
#endif
            // First preference: links that resolve to local markdown files
            // open as markdown tabs in cmux, not in the browser.
            let fileCandidate = url.scheme == "file" ? url.path : url.absoluteString
            if let markdownPath = resolvedMarkdownFilePath(fileCandidate) {
                openMarkdownFile(markdownPath)
                return
            }

            // Schemes the in-app browser doesn't (and shouldn't) handle:
            // mailto:, tel:, slack://, vscode://, file:// non-markdown, etc.
            // Route those to the system handler so the user's default app picks them up.
            if let scheme = url.scheme?.lowercased(),
               scheme != "http", scheme != "https" {
                NSWorkspace.shared.open(url)
                return
            }

            guard BrowserAvailabilitySettings.isEnabled() else {
                NSWorkspace.shared.open(url)
                return
            }

            guard let app = AppDelegate.shared,
                  let location = app.workspaceContainingPanel(
                      panelId: panelId,
                      preferredWorkspaceId: workspaceId
                  ),
                  let paneId = location.workspace.paneId(forPanelId: panelId) else {
                // No workspace context — last-resort fallback.
                NSWorkspace.shared.open(url)
                return
            }

            _ = location.workspace.newBrowserSurface(
                inPane: paneId,
                url: url,
                focus: true
            )
        }

        private func isInPageFragment(_ url: URL) -> Bool {
            // Only same-document anchors should stay inside the WebView. With
            // a file base URL, WebKit resolves `#heading` to
            // `file:///current.md#heading`; links such as `other.md#heading`
            // must still route through the markdown-tab opener below.
            guard url.fragment != nil else { return false }
            if (url.scheme == nil || url.scheme == "about"), (url.host ?? "").isEmpty {
                return true
            }
            if url.isFileURL {
                let targetPath = (url.path as NSString).standardizingPath
                let currentPath = (filePath as NSString).standardizingPath
                let currentDirectory = ((filePath as NSString).deletingLastPathComponent as NSString).standardizingPath
                return targetPath == currentPath || targetPath == currentDirectory
            }
            return false
        }
    }
}

extension NSColor {
    var markdownOpaqueSRGB: NSColor {
        (usingColorSpace(.sRGB) ?? self).withAlphaComponent(1)
    }

    var markdownCSSColor: String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let r = min(255, max(0, Int((red * 255).rounded())))
        let g = min(255, max(0, Int((green * 255).rounded())))
        let b = min(255, max(0, Int((blue * 255).rounded())))
        let a = min(1, max(0, alpha))
        return String(format: "rgba(%d, %d, %d, %.3f)", r, g, b, Double(a))
    }

    func markdownThemeOverlay(targetContrast: CGFloat, of color: NSColor) -> NSColor {
        let base = markdownOpaqueSRGB
        let overlay = color.markdownOpaqueSRGB
        var low: CGFloat = 0
        var high: CGFloat = 1
        var result: CGFloat = 1

        for _ in 0..<18 {
            let mid = (low + high) / 2
            let candidate = base.blended(withFraction: mid, of: overlay) ?? base
            if candidate.markdownContrastRatio(with: base) < Double(targetContrast) {
                low = mid
            } else {
                high = mid
                result = mid
            }
        }

        return overlay.withAlphaComponent(result)
    }

    var markdownRelativeLuminance: Double {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            if value <= 0.04045 {
                return value / 12.92
            }
            return pow((value + 0.055) / 1.055, 2.4)
        }

        return (0.2126 * linear(red)) + (0.7152 * linear(green)) + (0.0722 * linear(blue))
    }

    func markdownContrastRatio(with other: NSColor) -> Double {
        let first = markdownRelativeLuminance
        let second = other.markdownRelativeLuminance
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
