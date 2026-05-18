import AppKit
import Darwin
import Network
import Security
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
    static let localImageURLScheme = "cmux-local-image"
    static let remoteImageURLScheme = "cmux-remote-image"

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
        coordinator.cancelImageLoads()
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
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
        weak var webView: WKWebView?
        var panelId: UUID = UUID()
        var workspaceId: UUID = UUID()
        var filePath: String = ""
        private var pendingMarkdown: String = ""
        private var pendingTheme: MarkdownWebTheme = .resolve(backgroundColor: GhosttyBackgroundTheme.currentColor())
        private var lastMarkdown: String? = nil
        private var lastTheme: MarkdownWebTheme? = nil
        private var isLoaded = false
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

            let markdownDirectory = URL(fileURLWithPath: filePath)
                .deletingLastPathComponent()
                .standardizedFileURL
                .resolvingSymlinksInPath()
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

struct MarkdownRemoteImageFetchResult {
    let data: Data
    let mimeType: String
}

enum MarkdownRemoteImageSecurity {
    static let maximumRemoteImageBytes = 8 * 1024 * 1024

    static func remoteImageURL(from requestURL: URL) -> URL? {
        guard requestURL.scheme?.lowercased() == MarkdownWebRenderer.remoteImageURLScheme,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let rawRemoteURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let remoteURL = URL(string: rawRemoteURL),
              isPotentiallySafeRemoteImageURL(remoteURL) else {
            return nil
        }
        return remoteURL
    }

    static func isPotentiallySafeRemoteImageURL(_ url: URL) -> Bool {
        isSafeRemoteImageURL(url, resolveHost: false)
    }

    static func isSafeRemoteImageURL(_ url: URL, resolveHost: Bool = true) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host(percentEncoded: false),
              isAllowedHostNameOrLiteral(host) else {
            return false
        }
        return !resolveHost || hostResolvesOnlyToAllowedAddresses(host)
    }

    static func pinnedFetchTargets(for url: URL) -> [MarkdownRemoteImageFetchTarget] {
        guard isPotentiallySafeRemoteImageURL(url),
              let host = url.host(percentEncoded: false),
              let endpoints = resolvedAllowedEndpoints(for: host),
              !endpoints.isEmpty else {
            return []
        }
        return endpoints.map {
            MarkdownRemoteImageFetchTarget(url: url, serverName: host, endpointHost: $0, port: 443)
        }
    }

    static func pathAndQuery(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var value = components?.percentEncodedPath.isEmpty == false ? components?.percentEncodedPath ?? "/" : "/"
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            value += "?\(query)"
        }
        return value
    }

    static func requestBytes(for url: URL, host: String) -> Data? {
        guard let hostHeader = httpHostHeaderValue(for: host) else { return nil }
        let request = [
            "GET \(pathAndQuery(for: url)) HTTP/1.1",
            "Host: \(hostHeader)",
            "Accept: image/png,image/jpeg,image/gif,image/webp,image/avif;q=0.9,*/*;q=0.1",
            "User-Agent: cmux-markdown-image-loader",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        return request.data(using: .utf8)
    }

    static func remoteImageConsentHost(for url: URL) -> String? {
        guard isPotentiallySafeRemoteImageURL(url),
              let host = url.host(percentEncoded: false) else {
            return nil
        }
        let normalized = normalizedRemoteImageHost(host)
        return normalized.isEmpty ? nil : normalized
    }

    static func canonicalImageMIMEType(_ raw: String?) -> String? {
        let mimeType = String(raw ?? "")
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch mimeType {
        case "image/png":
            return "image/png"
        case "image/jpeg", "image/jpg":
            return "image/jpeg"
        case "image/gif":
            return "image/gif"
        case "image/webp":
            return "image/webp"
        case "image/avif":
            return "image/avif"
        default:
            return nil
        }
    }

    private static func normalizedRemoteImageHost(_ rawHost: String) -> String {
        rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]").union(.whitespacesAndNewlines))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private static func isAllowedHostNameOrLiteral(_ rawHost: String) -> Bool {
        let host = normalizedRemoteImageHost(rawHost)
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        if host == "local" || host.hasSuffix(".local") { return false }
        if let bytes = ipv4Bytes(host) {
            return isAllowedIPv4Address(bytes)
        }
        if let bytes = ipv6Bytes(host) {
            return isAllowedIPv6Address(bytes)
        }
        return true
    }

    private static func hostResolvesOnlyToAllowedAddresses(_ rawHost: String) -> Bool {
        guard let endpoints = resolvedAllowedEndpoints(for: rawHost) else { return false }
        return !endpoints.isEmpty
    }

    private static func resolvedAllowedEndpoints(for rawHost: String) -> [NWEndpoint.Host]? {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let bytes = ipv4Bytes(host) {
            guard isAllowedIPv4Address(bytes),
                  let endpoint = ipv4Endpoint(bytes) else { return nil }
            return [endpoint]
        }
        if let bytes = ipv6Bytes(host) {
            guard isAllowedIPv6Address(bytes),
                  let endpoint = ipv6Endpoint(bytes) else { return nil }
            return [endpoint]
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }

        var endpoints: [NWEndpoint.Host] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ai_next }
            guard let address = current.pointee.ai_addr else { continue }
            switch current.pointee.ai_family {
            case AF_INET:
                let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin_addr.s_addr) { Array($0) }
                }
                guard isAllowedIPv4Address(bytes),
                      let endpoint = ipv4Endpoint(bytes) else { return nil }
                endpoints.append(endpoint)
            case AF_INET6:
                let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                }
                guard isAllowedIPv6Address(bytes),
                      let endpoint = ipv6Endpoint(bytes) else { return nil }
                endpoints.append(endpoint)
            default:
                continue
            }
        }
        var seen = Set<String>()
        return endpoints.filter { seen.insert(String(describing: $0)).inserted }
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var address = in_addr()
        let result = host.withCString { inet_pton(AF_INET, $0, &address) }
        guard result == 1 else { return nil }
        return Array(withUnsafeBytes(of: address.s_addr) { $0 })
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        let result = host.withCString { inet_pton(AF_INET6, $0, &address) }
        guard result == 1 else { return nil }
        return Array(withUnsafeBytes(of: address) { $0 })
    }

    private static func isAllowedIPv4Address(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        if first == 0 { return false }
        if first == 10 { return false }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 127 { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 && second == 0 { return false }
        if first == 192 && second == 168 { return false }
        if first == 198 && (18...19).contains(second) { return false }
        if first >= 224 { return false }
        return true
    }

    private static func isAllowedIPv6Address(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false }
        if bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0 { return false }
        if bytes[0] == 0xff { return false }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) { return false }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isAllowedIPv4Address(Array(bytes[12..<16]))
        }
        return true
    }

    private static func ipv4Endpoint(_ bytes: [UInt8]) -> NWEndpoint.Host? {
        guard bytes.count == 4 else { return nil }
        let value = bytes.map(String.init).joined(separator: ".")
        guard let address = IPv4Address(value) else { return nil }
        return .ipv4(address)
    }

    private static func ipv6Endpoint(_ bytes: [UInt8]) -> NWEndpoint.Host? {
        guard bytes.count == 16 else { return nil }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { buffer in
            for index in bytes.indices {
                buffer[index] = bytes[index]
            }
        }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return withUnsafePointer(to: &address) { pointer in
            guard inet_ntop(AF_INET6, pointer, &output, socklen_t(output.count)) != nil else {
                return nil
            }
            let value = String(cString: output)
            guard let networkAddress = IPv6Address(value) else { return nil }
            return .ipv6(networkAddress)
        }
    }

    private static func isSafeHTTPHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { byte in
            byte >= 0x21 && byte != 0x7f
        }
    }

    private static func httpHostHeaderValue(for rawHost: String) -> String? {
        let host = normalizedRemoteImageHost(rawHost)
        guard isSafeHTTPHeaderValue(host) else { return nil }
        if ipv6Bytes(host) != nil {
            return "[\(host)]"
        }
        return host
    }
}

struct MarkdownRemoteImageFetchTarget {
    let url: URL
    let serverName: String
    let endpointHost: NWEndpoint.Host
    let port: UInt16
}

enum MarkdownRemoteImageFetcher {
    static func fetch(_ url: URL) async -> MarkdownRemoteImageFetchResult? {
        guard !Task.isCancelled,
              let approvedHost = MarkdownRemoteImageSecurity.remoteImageConsentHost(for: url) else {
            return nil
        }
        return await fetch(url, approvedHost: approvedHost, redirectDepth: 0)
    }

    private static func fetch(
        _ url: URL,
        approvedHost: String,
        redirectDepth: Int
    ) async -> MarkdownRemoteImageFetchResult? {
        guard !Task.isCancelled,
              redirectDepth <= 3 else { return nil }
        let targets = MarkdownRemoteImageSecurity.pinnedFetchTargets(for: url)
        guard !Task.isCancelled else { return nil }
        for target in targets {
            guard !Task.isCancelled else { return nil }
            let loader = MarkdownPinnedRemoteImageLoader(
                target: target,
                maximumBytes: MarkdownRemoteImageSecurity.maximumRemoteImageBytes
            )
            switch await loader.fetch() {
            case .image(let result):
                guard !Task.isCancelled else { return nil }
                return result
            case .redirect(let redirectURL):
                guard !Task.isCancelled,
                      let resolvedRedirect = URL(string: redirectURL.absoluteString, relativeTo: url)?.absoluteURL,
                      MarkdownRemoteImageSecurity.remoteImageConsentHost(for: resolvedRedirect) == approvedHost else {
                    return nil
                }
                return await fetch(
                    resolvedRedirect,
                    approvedHost: approvedHost,
                    redirectDepth: redirectDepth + 1
                )
            case .none:
                continue
            }
        }
        return nil
    }
}

private enum MarkdownRemoteImageLoadOutcome {
    case image(MarkdownRemoteImageFetchResult)
    case redirect(URL)
}

private final class MarkdownPinnedRemoteImageLoader {
    private let maximumBytes: Int
    private let target: MarkdownRemoteImageFetchTarget
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.cmux.markdown-remote-image", qos: .userInitiated)
    private var rawBody = Data()
    private var mimeType = "image/png"
    private var completion: ((MarkdownRemoteImageLoadOutcome?) -> Void)?
    private var connection: NWConnection?
    private var headerParsed = false
    private var usesChunkedTransfer = false
    private var expectedBodyBytes: Int?
    private var timeoutWorkItem: DispatchWorkItem?
    private var completed = false

    init(target: MarkdownRemoteImageFetchTarget, maximumBytes: Int) {
        self.target = target
        self.maximumBytes = maximumBytes
    }

    func fetch() async -> MarkdownRemoteImageLoadOutcome? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                start { outcome in
                    continuation.resume(returning: outcome)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        finish(nil)
    }

    private func start(completion: @escaping (MarkdownRemoteImageLoadOutcome?) -> Void) {
        guard let requestData = MarkdownRemoteImageSecurity.requestBytes(
            for: target.url,
            host: target.serverName
        ) else {
            completion(nil)
            return
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, target.serverName)
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { [serverName = target.serverName] _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let policy = SecPolicyCreateSSL(true, serverName as CFString)
                SecTrustSetPolicies(secTrust, policy)
                var error: CFError?
                complete(SecTrustEvaluateWithError(secTrust, &error))
            },
            queue
        )

        let parameters = NWParameters(tls: tls)
        parameters.includePeerToPeer = false
        guard let endpointPort = NWEndpoint.Port(rawValue: target.port) else {
            completion(nil)
            return
        }
        let connection = NWConnection(to: .hostPort(host: target.endpointHost, port: endpointPort), using: parameters)
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(nil)
        }
        lock.lock()
        guard !completed else {
            lock.unlock()
            completion(nil)
            return
        }
        self.connection = connection
        self.completion = completion
        timeoutWorkItem = timeout
        lock.unlock()

        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        connection.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            switch state {
            case .ready:
                self?.send(requestData)
            case .failed, .cancelled:
                self?.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func send(_ requestData: Data) {
        currentConnection()?.send(content: requestData, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                self?.finish(nil)
                return
            }
            self?.receiveNext()
        })
    }

    private func receiveNext() {
        currentConnection()?.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                finish(nil)
                return
            }

            if let data, !data.isEmpty {
                switch process(data) {
                case .continue:
                    break
                case .finish(let outcome):
                    finish(outcome)
                    return
                case .fail:
                    finish(nil)
                    return
                }
            }

            if isComplete {
                finish(finalOutcome())
                return
            }
            receiveNext()
        }
    }

    private enum ProcessResult {
        case `continue`
        case finish(MarkdownRemoteImageLoadOutcome)
        case fail
    }

    private func process(_ data: Data) -> ProcessResult {
        rawBody.append(data)
        if !headerParsed {
            guard let delimiter = rawBody.range(of: Data([13, 10, 13, 10])) else {
                return rawBody.count > 64 * 1024 ? .fail : .continue
            }
            let headerData = rawBody[..<delimiter.lowerBound]
            let remaining = rawBody[delimiter.upperBound...]
            rawBody = Data(remaining)
            switch parseHeaders(headerData) {
            case .continue:
                headerParsed = true
            case .finish(let outcome):
                return .finish(outcome)
            case .fail:
                return .fail
            }
        }

        if rawBody.count > maximumBytes + 64 * 1024 {
            return .fail
        }
        if !usesChunkedTransfer, rawBody.count > maximumBytes {
            return .fail
        }
        if !usesChunkedTransfer, let expectedBodyBytes, rawBody.count >= expectedBodyBytes {
            rawBody = Data(rawBody.prefix(expectedBodyBytes))
            guard let outcome = finalOutcome() else { return .fail }
            return .finish(outcome)
        }
        return .continue
    }

    private func parseHeaders(_ headerData: Data) -> ProcessResult {
        guard let rawHeaders = String(data: headerData, encoding: .isoLatin1) else {
            return .fail
        }
        let lines = rawHeaders.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return .fail }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2,
              let statusCode = Int(statusParts[1]) else {
            return .fail
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        if (300..<400).contains(statusCode),
           let location = headers["location"],
           let redirectURL = URL(string: location, relativeTo: target.url)?.absoluteURL,
           MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(redirectURL) {
            return .finish(.redirect(redirectURL))
        }

        guard (200..<300).contains(statusCode),
              let responseMIMEType = MarkdownRemoteImageSecurity.canonicalImageMIMEType(headers["content-type"]) else {
            return .fail
        }

        if let transferEncoding = headers["transfer-encoding"]?.lowercased(),
           transferEncoding.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "chunked" }) {
            usesChunkedTransfer = true
        }

        if let contentLength = headers["content-length"].flatMap(Int.init) {
            guard contentLength >= 0, contentLength <= maximumBytes else { return .fail }
            expectedBodyBytes = contentLength
        }

        mimeType = responseMIMEType
        return .continue
    }

    private func finalOutcome() -> MarkdownRemoteImageLoadOutcome? {
        guard headerParsed else { return nil }
        let body: Data
        if usesChunkedTransfer {
            guard let decoded = MarkdownHTTPChunkedBodyDecoder.decode(
                rawBody,
                maximumBytes: maximumBytes
            ) else {
                return nil
            }
            body = decoded
        } else {
            if let expectedBodyBytes, rawBody.count != expectedBodyBytes {
                return nil
            }
            body = rawBody
        }
        guard body.count <= maximumBytes else { return nil }
        return .image(MarkdownRemoteImageFetchResult(data: body, mimeType: mimeType))
    }

    private func currentConnection() -> NWConnection? {
        lock.lock()
        let value = connection
        lock.unlock()
        return value
    }

    private func finish(_ outcome: MarkdownRemoteImageLoadOutcome?) {
        let callback: ((MarkdownRemoteImageLoadOutcome?) -> Void)?
        let connectionToCancel: NWConnection?
        let timeoutToCancel: DispatchWorkItem?
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        callback = completion
        completion = nil
        connectionToCancel = connection
        connection = nil
        timeoutToCancel = timeoutWorkItem
        timeoutWorkItem = nil
        lock.unlock()

        timeoutToCancel?.cancel()
        connectionToCancel?.cancel()
        callback?(outcome)
    }
}

enum MarkdownHTTPChunkedBodyDecoder {
    static func decode(_ data: Data, maximumBytes: Int) -> Data? {
        let bytes = Array(data)
        var offset = 0
        var decoded = Data()

        while offset < bytes.count {
            guard let lineEnd = crlfIndex(in: bytes, from: offset) else { return nil }
            let sizeLineBytes = bytes[offset..<lineEnd]
            guard let sizeLine = String(bytes: sizeLineBytes, encoding: .ascii) else { return nil }
            let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first ?? ""
            guard let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16) else {
                return nil
            }
            offset = lineEnd + 2
            if size == 0 {
                return decoded
            }
            let remainingBytes = bytes.count - offset
            guard size >= 0,
                  size <= maximumBytes,
                  decoded.count <= maximumBytes - size,
                  remainingBytes >= 2,
                  size <= remainingBytes - 2 else {
                return nil
            }
            let chunkEnd = offset + size
            guard bytes[chunkEnd] == 13,
                  bytes[chunkEnd + 1] == 10 else {
                return nil
            }
            decoded.append(contentsOf: bytes[offset..<offset + size])
            guard decoded.count <= maximumBytes else { return nil }
            offset += size + 2
        }
        return nil
    }

    private static func crlfIndex(in bytes: [UInt8], from offset: Int) -> Int? {
        guard offset < bytes.count else { return nil }
        var index = offset
        while index + 1 < bytes.count {
            if bytes[index] == 13, bytes[index + 1] == 10 {
                return index
            }
            index += 1
        }
        return nil
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
