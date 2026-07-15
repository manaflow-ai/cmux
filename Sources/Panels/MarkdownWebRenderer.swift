import AppKit
import SwiftUI
import WebKit

struct MarkdownWebRenderer: NSViewRepresentable {
    static let localImageURLScheme = "cmux-local-image"
    static let remoteImageURLScheme = "cmux-remote-image"

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
            applyBackground(to: webView)
            applyAppearance(to: webView, isDark: theme.isDark)
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
            context.coordinator,
            forURLScheme: Self.localImageURLScheme
        )
        config.setURLSchemeHandler(
            context.coordinator,
            forURLScheme: Self.remoteImageURLScheme
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
        applyBackground(to: nsView)
        applyAppearance(to: nsView, isDark: theme.isDark)
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
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
        var webView: MarkdownWebView?
        var panelId: UUID = UUID()
        var workspaceId: UUID = UUID()
        var filePath: String = ""
        private var pendingMarkdown: String = ""
        private var pendingTheme: MarkdownWebTheme = .resolve(backgroundColor: GhosttyBackgroundTheme.currentColor())
        private var lastMarkdown: String? = nil
        private var lastTheme: MarkdownWebTheme? = nil
        private var lastFontFamily: String = ""
        private var lastFontSize: Double = MarkdownFontSizeSettings.defaultPointSize
        private var lastMaxContentWidth: Double = MarkdownMaxWidthSettings.defaultCSSPixels
        private var isLoaded = false
        private var isShellLoading = false
        private var webContentProcessRecoveryAttempts = 0
        private let maxWebContentProcessRecoveryAttempts = 2
        /// Whether the shell was confirmed loaded at the moment the host view
        /// last left its window. Used to distinguish a blank state caused by
        /// detaching the pane (WebKit suspending/reclaiming the detached view —
        /// recoverable) from one caused by a payload that keeps crashing
        /// WebContent while attached (a crash loop whose recovery budget must
        /// not be reset by pane reparenting).
        private var shellWasHealthyWhenDetached = false

        private struct ImageLoadResult {
            let data: Data
            let mimeType: String
        }

        private final class ImageLoad {
            var reader: Task<ImageLoadResult, Never>?
            var sender: Task<Void, Never>?

            func cancel() {
                reader?.cancel()
                sender?.cancel()
            }
        }
        private var imageLoads: [ObjectIdentifier: ImageLoad] = [:]

#if DEBUG
        var isShellLoadingForTesting: Bool {
            isShellLoading
        }

        var webContentProcessRecoveryAttemptsForTesting: Int {
            webContentProcessRecoveryAttempts
        }
#endif

        func bind(panelId: UUID, workspaceId: UUID, filePath: String) {
            self.panelId = panelId
            self.workspaceId = workspaceId
            self.filePath = filePath
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
            if shouldSyncShell { webView.evaluateJavaScript("window.__cmuxSetMarkdownZoom && window.__cmuxSetMarkdownZoom(\(Double(zoom)));", completionHandler: nil) }
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
            // JSON-encode the CSS value (empty string clears the override).
            let css = MarkdownFontFamily.cssValue(for: lastFontFamily) ?? ""
            let encoded = (try? JSONSerialization.data(withJSONObject: [css]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            let js = """
            (function(arr) {
              var content = document.getElementById('content');
              if (content) { content.style.fontFamily = arr[0]; }
            })(\(encoded));
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
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
            let js = """
            (function(width) {
              var content = document.getElementById('content');
              if (content) { content.style.maxWidth = width + 'px'; }
            })(\(width));
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
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
            webContentProcessRecoveryAttempts = 0
            shellWasHealthyWhenDetached = false
            cancelImageLoads()
            requestedLibs.removeAll()
        }

        func loadShell(theme: MarkdownWebTheme, initialMarkdown: String) {
            pendingMarkdown = initialMarkdown
            pendingTheme = theme
            lastTheme = theme
            requestedLibs.removeAll()
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
                webContentProcessRecoveryAttempts = 0
                lastMarkdown = markdown
                if isLoaded {
                    pushMarkdown(markdown)
                } else if shellNeedsReload {
                    loadShell(theme: theme, initialMarkdown: markdown)
                }
            } else if shellNeedsReload {
                if webContentProcessRecoveryAttempts < maxWebContentProcessRecoveryAttempts {
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

        // MARK: WKURLSchemeHandler

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let requestURL = urlSchemeTask.request.url else {
                urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
                return
            }

            let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)
            let load = ImageLoad()
            imageLoads[taskId] = load
            let reader = imageLoadTask(for: requestURL)
            load.reader = reader
            let sender = Task { [weak self, weak load] in
                defer {
                    if let load, self?.imageLoads[taskId] === load {
                        self?.imageLoads[taskId] = nil
                    }
                }
                let result = await reader.value
                guard !Task.isCancelled else { return }
                let response = URLResponse(
                    url: requestURL,
                    mimeType: result.mimeType,
                    expectedContentLength: result.data.count,
                    textEncodingName: nil
                )
                urlSchemeTask.didReceive(response)
                if !result.data.isEmpty {
                    urlSchemeTask.didReceive(result.data)
                }
                urlSchemeTask.didFinish()
            }
            load.sender = sender
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)
            guard let load = imageLoads.removeValue(forKey: taskId) else { return }
            load.cancel()
        }

        func cancelImageLoads() {
            let loads = imageLoads.values
            imageLoads.removeAll()
            for load in loads {
                load.cancel()
            }
        }

        func cancelLocalImageLoads() {
            cancelImageLoads()
        }

        private func imageLoadTask(for requestURL: URL) -> Task<ImageLoadResult, Never> {
            let scheme = requestURL.scheme?.lowercased()
            if scheme == MarkdownWebRenderer.localImageURLScheme {
                let fileURL = localImageFileURL(from: requestURL)
                let mimeType = fileURL
                    .flatMap { Self.localImageMimeType(for: $0.pathExtension) } ?? "image/png"
                return Task.detached(priority: .userInitiated) {
                    guard let fileURL,
                          FileManager.default.isReadableFile(atPath: fileURL.path) else {
                        return ImageLoadResult(data: Data(), mimeType: mimeType)
                    }
                    let data = (try? Data(contentsOf: fileURL)) ?? Data()
                    return ImageLoadResult(data: data, mimeType: mimeType)
                }
            }

            if scheme == MarkdownWebRenderer.remoteImageURLScheme {
                let remoteURL = MarkdownRemoteImageSecurity.remoteImageURL(from: requestURL)
                return Task.detached(priority: .userInitiated) {
                    guard let remoteURL,
                          let fetched = await MarkdownRemoteImageFetcher.fetch(remoteURL) else {
                        return ImageLoadResult(data: Data(), mimeType: "image/png")
                    }
                    return ImageLoadResult(data: fetched.data, mimeType: fetched.mimeType)
                }
            }

            return Task.detached {
                ImageLoadResult(data: Data(), mimeType: "image/png")
            }
        }

        private func localImageFileURL(from requestURL: URL) -> URL? {
            guard requestURL.scheme?.lowercased() == MarkdownWebRenderer.localImageURLScheme,
                  let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
                  let rawFileURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  let fileURL = URL(string: rawFileURL),
                  fileURL.isFileURL else {
                return nil
            }

            let markdownFilePath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markdownFilePath.isEmpty else {
                return nil
            }

            let markdownDirectory = URL(fileURLWithPath: markdownFilePath)
                .deletingLastPathComponent()
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard markdownDirectory.path != "/" else {
                return nil
            }

            let markdownRoot = markdownDirectory.path.hasSuffix("/")
                ? markdownDirectory.path
                : markdownDirectory.path + "/"
            let standardizedURL = fileURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard standardizedURL.path.hasPrefix(markdownRoot),
                  Self.localImageMimeType(for: standardizedURL.pathExtension) != nil else {
                return nil
            }
            return standardizedURL
        }

        private static func localImageMimeType(for pathExtension: String) -> String? {
            switch pathExtension.lowercased() {
            case "png":
                return "image/png"
            case "jpg", "jpeg":
                return "image/jpeg"
            case "gif":
                return "image/gif"
            case "webp":
                return "image/webp"
            case "avif":
                return "image/avif"
            default:
                return nil
            }
        }

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
            case "mathjax":
                sources = [assets.lazyAsset(name: "mathjax-tex-svg.min", ext: "js")]
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
            guard webContentProcessRecoveryAttempts < maxWebContentProcessRecoveryAttempts else {
                isLoaded = false
                requestedLibs.removeAll()
                return
            }
            webContentProcessRecoveryAttempts += 1
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
            shellWasHealthyWhenDetached = isLoaded
        }

        func handleViewReenteredWindow() {
            // A still-loaded shell — alive but merely unpainted — is left
            // intact; the host view's repaint nudge handles that case.
            guard !isLoaded else { return }
            // Recover only when the document was healthy before the detach, so
            // a payload that exhausted its crash-recovery budget while attached
            // (a crash loop) is not granted a fresh budget by pane reparenting.
            guard shellWasHealthyWhenDetached else { return }
            shellWasHealthyWhenDetached = false
            // A reload kicked off while detached can stall (no didFinish until
            // the view is back in a window), so reload unconditionally — even
            // mid-load. A deliberate reattach is not a crash loop, so restore
            // the recovery budget so the document repaints instead of staying
            // permanently blank.
            webContentProcessRecoveryAttempts = 0
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

    }
}
