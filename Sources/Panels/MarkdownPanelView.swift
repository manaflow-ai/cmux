import AppKit
import SwiftUI
import WebKit

/// SwiftUI view that renders a MarkdownPanel's content in a WKWebView using
/// marked.js + github-markdown-css + highlight.js.
///
/// We render through a web view (rather than the previous MarkdownUI path)
/// so that:
///   - Native browser text selection works across the entire document
///     (Cmd+A / drag-select span paragraphs, headings, code blocks, etc.).
///     MarkdownUI rendered each block as an isolated SwiftUI `Text`, which
///     made it impossible to select more than one block at a time.
///   - Rendering uses GitHub's actual markdown CSS, so tables, task lists,
///     nested lists, blockquotes, and code blocks look identical to what
///     users see on github.com.
///   - We can copy the rendered HTML straight from the same source the user
///     is reading.
struct MarkdownPanelView: View {
    @ObservedObject var panel: MarkdownPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @State private var copyConfirmation: CopyConfirmation? = nil
    @State private var renderer = MarkdownWebRendererHandle()
    @Environment(\.colorScheme) private var colorScheme

    private enum CopyConfirmation: Equatable {
        case markdown
        case html

        var label: String {
            switch self {
            case .markdown:
                return String(localized: "markdown.copyConfirm.markdown", defaultValue: "Copied as Markdown")
            case .html:
                return String(localized: "markdown.copyConfirm.html", defaultValue: "Copied as HTML")
            }
        }
    }

    var body: some View {
        Group {
            if panel.isFileUnavailable {
                fileUnavailableView
            } else {
                markdownContentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if !panel.isFileUnavailable {
                MarkdownPanelToolbar(
                    confirmation: copyConfirmation?.label,
                    onCopyMarkdown: { copyAsMarkdown() },
                    onCopyHTML: { copyAsHTML() }
                )
                .padding(.top, 10)
                .padding(.trailing, 14)
            }
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
    }

    // MARK: - Content

    private var markdownContentView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File path breadcrumb
            filePathHeader
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 16)

            MarkdownWebRenderer(
                markdown: panel.content,
                isDark: colorScheme == .dark,
                panelId: panel.id,
                workspaceId: panel.workspaceId,
                filePath: panel.filePath,
                handle: renderer,
                onRequestPanelFocus: onRequestPanelFocus
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filePathHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.richtext")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            Text(panel.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private var fileUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(String(localized: "markdown.fileUnavailable.title", defaultValue: "File unavailable"))
                .font(.headline)
                .foregroundColor(.primary)
            Text(panel.filePath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text(String(localized: "markdown.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Theme

    private var backgroundColor: Color {
        // Match GitHub's --bgColor-default for each color scheme.
        colorScheme == .dark
            ? Color(nsColor: NSColor(red: 0x0d / 255.0, green: 0x11 / 255.0, blue: 0x17 / 255.0, alpha: 1.0))
            : Color(nsColor: NSColor(white: 1.0, alpha: 1.0))
    }

    // MARK: - Copy actions

    private func copyAsMarkdown() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(panel.content, forType: .string)
        flashCopyConfirmation(.markdown)
    }

    private func copyAsHTML() {
        renderer.requestRenderedHTML { html in
            let payload = html ?? ""
            let pb = NSPasteboard.general
            pb.clearContents()
            // public.html for rich-text-aware targets (Notes, Mail, Pages, ...)
            // and a plain-text fallback so plain editors still receive content.
            pb.setString(payload, forType: .html)
            pb.setString(payload, forType: .string)
            flashCopyConfirmation(.html)
        }
    }

    private func flashCopyConfirmation(_ kind: CopyConfirmation) {
        copyConfirmation = kind
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copyConfirmation == kind {
                copyConfirmation = nil
            }
        }
    }

    // MARK: - Focus Flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

// MARK: - Toolbar

private struct MarkdownPanelToolbar: View {
    let confirmation: String?
    let onCopyMarkdown: () -> Void
    let onCopyHTML: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            if let confirmation {
                Text(confirmation)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(toolbarBackground.opacity(0.85))
                    )
                    .transition(.opacity)
            }

            toolbarButton(
                title: String(localized: "markdown.toolbar.copyMarkdown", defaultValue: "Copy as Markdown"),
                systemImage: "doc.on.doc",
                action: onCopyMarkdown
            )
            toolbarButton(
                title: String(localized: "markdown.toolbar.copyHTML", defaultValue: "Copy as HTML"),
                systemImage: "chevron.left.forwardslash.chevron.right",
                action: onCopyHTML
            )
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(toolbarBackground.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(toolbarBorder, lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.1), radius: 4, y: 1)
        )
        .animation(.easeOut(duration: 0.15), value: confirmation)
    }

    private func toolbarButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(MarkdownToolbarButtonStyle())
        .help(title)
        .accessibilityLabel(title)
    }

    private var toolbarBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.18, alpha: 1.0))
            : Color(nsColor: NSColor(white: 1.0, alpha: 1.0))
    }

    private var toolbarBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
    }
}

private struct MarkdownToolbarButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.isPressed ? .secondary : .primary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isPressed
                          ? (colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                          : Color.clear)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Renderer handle

/// Lightweight reference object the SwiftUI view holds across re-renders so
/// it can talk to the underlying WKWebView (primarily to fetch the rendered
/// HTML for "Copy as HTML"). Owned via @State; the coordinator registers
/// itself when the NSView is created.
final class MarkdownWebRendererHandle {
    fileprivate weak var coordinator: MarkdownWebRenderer.Coordinator?

    func requestRenderedHTML(_ completion: @escaping (String?) -> Void) {
        guard let coordinator else { completion(nil); return }
        coordinator.fetchRenderedHTML(completion)
    }
}

final class MarkdownWebView: WKWebView {
    var onPointerDown: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        super.mouseDown(with: event)
    }
}

// MARK: - Web view renderer

private struct MarkdownWebRenderer: NSViewRepresentable {
    let markdown: String
    let isDark: Bool
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
        applyAppearance(to: webView, isDark: isDark)

        context.coordinator.webView = webView
        context.coordinator.loadShell(isDark: isDark, initialMarkdown: markdown)
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
        applyAppearance(to: nsView, isDark: isDark)
        context.coordinator.update(markdown: markdown, isDark: isDark)
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var panelId: UUID = UUID()
        var workspaceId: UUID = UUID()
        var filePath: String = ""
        private var pendingMarkdown: String = ""
        private var lastMarkdown: String? = nil
        private var lastIsDark: Bool? = nil
        private var isLoaded = false

        func loadShell(isDark: Bool, initialMarkdown: String) {
            pendingMarkdown = initialMarkdown
            lastIsDark = isDark
            requestedLibs.removeAll()
            isLoaded = false
            let html = MarkdownViewerAssets.shared.shellHTML(isDark: isDark)
            let baseURL = URL(fileURLWithPath: filePath)
#if DEBUG
            NSLog("MarkdownPanel.loadShell filePath=\(filePath) baseURL=\(baseURL.absoluteString) htmlBytes=\(html.utf8.count)")
#endif
            webView?.loadHTMLString(html, baseURL: baseURL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.pushMarkdown(self.lastMarkdown ?? self.pendingMarkdown)
            }
        }

        func update(markdown: String, isDark: Bool) {
            let themeChanged = lastIsDark != isDark
            let contentChanged = lastMarkdown != markdown
            guard themeChanged || contentChanged else { return }

            pendingMarkdown = markdown

            if themeChanged {
                lastIsDark = isDark
                // The WKWebView's NSAppearance change (handled in the
                // representable's update path) flips `prefers-color-scheme`
                // automatically. We still nudge the page so highlight.js
                // swaps stylesheets even if the matchMedia listener is
                // slow to fire.
                if isLoaded, let webView {
                    let js = "window.__cmuxApplyTheme && window.__cmuxApplyTheme();"
                    webView.evaluateJavaScript(js, completionHandler: nil)
                }
            }

            if contentChanged {
                lastMarkdown = markdown
                if isLoaded {
                    pushMarkdown(markdown)
                }
            }
        }

        func fetchRenderedHTML(_ completion: @escaping (String?) -> Void) {
            guard let webView, isLoaded else { completion(nil); return }
            // We export an explicit "rendered HTML" getter from JS so callers
            // get the *content* div only, without the shell <style>/<script>.
            webView.evaluateJavaScript("window.__cmuxRenderedHTML && window.__cmuxRenderedHTML()") { result, _ in
                completion(result as? String)
            }
        }

        // MARK: Bridge

        private func pushMarkdown(_ markdown: String) {
            guard let webView else { return }
#if DEBUG
            NSLog("MarkdownPanel.pushMarkdown bytes=\(markdown.utf8.count)")
#endif
            // Send the raw markdown through a JSON literal so we don't have
            // to hand-escape backticks/backslashes/quotes for JS.
            guard let data = try? JSONSerialization.data(withJSONObject: [markdown]),
                  let arrayLiteral = String(data: data, encoding: .utf8) else { return }
            let js = """
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
            webView.evaluateJavaScript(js) { _, error in
#if DEBUG
                if let error {
                    NSLog("MarkdownPanel: pushMarkdown evaluateJavaScript failed: \(error)")
                }
#endif
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
            // Load each library at most once per WebView lifetime. If the
            // shell is reloaded (theme switch), state is reset alongside.
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

            // Inject each source as its own script tag via document.head so
            // that thrown errors get reported through the page console
            // rather than as a single opaque evaluateJavaScript failure.
            // Then notify the page that the lib is ready.
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

// MARK: - Markdown file link resolution

enum MarkdownPanelFileLinkResolver {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mkd", "mdx"]

    static func isMarkdownPathLike(_ rawPath: String) -> Bool {
        let trimmed = stripFragmentAndQuery(rawPath)
        guard !trimmed.isEmpty else { return false }
        // Keep this intentionally path-like: code spans such as `foo.md`,
        // `docs/foo.md`, `../foo.md`, or `/tmp/foo.md` qualify. URLs do not.
        if let url = URL(string: trimmed), url.scheme != nil, url.scheme != "file" {
            return false
        }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        return markdownExtensions.contains(ext)
    }

    static func resolve(rawPath: String, relativeToMarkdownFile markdownFilePath: String) -> String? {
        let stripped = stripFragmentAndQuery(rawPath)
        guard !stripped.isEmpty else { return nil }

        let candidatePaths: [String] = {
            if let url = URL(string: stripped), url.scheme == "file" {
                return [url.path]
            }
            if (stripped as NSString).isAbsolutePath {
                return [stripped]
            }
            let markdownDir = (markdownFilePath as NSString).deletingLastPathComponent
            let pwd = FileManager.default.currentDirectoryPath
            return [
                (markdownDir as NSString).appendingPathComponent(stripped),
                (pwd as NSString).appendingPathComponent(stripped)
            ]
        }()

        for path in candidatePaths {
            let standardized = (path as NSString).standardizingPath
            guard isMarkdownPathLike(standardized) else { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir), !isDir.boolValue {
                return standardized
            }
        }
        return nil
    }

    private static func stripFragmentAndQuery(_ rawPath: String) -> String {
        var s = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = s.firstIndex(of: "#") {
            s = String(s[..<hash])
        }
        if let question = s.firstIndex(of: "?") {
            s = String(s[..<question])
        }
        return s.removingPercentEncoding ?? s
    }
}

// MARK: - Bundled web assets

/// Loads marked.js, github-markdown-css, and highlight.js (with GitHub light
/// + dark themes) once and caches them. These files live under
/// `Resources/markdown-viewer/` and are copied into the app bundle as a
/// folder reference.
private final class MarkdownViewerAssets {
    static let shared = MarkdownViewerAssets()

    let markedJS: String
    let highlightJS: String
    let highlightLightCSS: String
    let highlightDarkCSS: String
    let githubMarkdownCSS: String

    /// Heavy libs (mermaid ≈ 2.5 MB, vega ≈ 800 KB) are loaded lazily
    /// the first time a markdown document needs them. Cached after first read.
    private var lazyCache: [String: String] = [:]
    private let lazyCacheLock = NSLock()

    private init() {
        markedJS = MarkdownViewerAssets.loadAsset(name: "marked.min", ext: "js")
        highlightJS = MarkdownViewerAssets.loadAsset(name: "highlight.min", ext: "js")
        highlightLightCSS = MarkdownViewerAssets.loadAsset(name: "highlight-github", ext: "css")
        highlightDarkCSS = MarkdownViewerAssets.loadAsset(name: "highlight-github-dark", ext: "css")
        githubMarkdownCSS = MarkdownViewerAssets.loadAsset(name: "github-markdown", ext: "css")
    }

    /// Load (and cache) a bundled JS asset on demand.
    func lazyAsset(name: String, ext: String) -> String {
        let key = "\(name).\(ext)"
        lazyCacheLock.lock()
        if let cached = lazyCache[key] {
            lazyCacheLock.unlock()
            return cached
        }
        lazyCacheLock.unlock()

        let source = MarkdownViewerAssets.loadAsset(name: name, ext: ext)

        lazyCacheLock.lock()
        lazyCache[key] = source
        lazyCacheLock.unlock()
        return source
    }

    private static func loadAsset(name: String, ext: String) -> String {
        // Folder references (Resources/markdown-viewer/) flatten into the
        // bundle as a subdirectory; both the subdirectory lookup and the
        // top-level lookup are tried so the bundle layout can vary.
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: ext, subdirectory: "markdown-viewer"),
            bundle.url(forResource: name, withExtension: ext)
        ]
        for case let url? in candidates {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                return s
            }
        }
#if DEBUG
        NSLog("MarkdownViewerAssets: missing bundled asset \(name).\(ext)")
#endif
        return ""
    }

    func shellHTML(isDark: Bool) -> String {
        _ = isDark // theme is driven by NSAppearance + prefers-color-scheme
        // The shell ships with empty content; markdown is pushed in via JS so
        // file-watch updates don't reset the user's scroll position.
        //
        // Layout / styling notes:
        //   - github-markdown-css gives us all block + inline rules (tables,
        //     task lists, blockquotes, kbd, footnotes, ...).
        //   - We scope it via `.markdown-body` (the convention the package
        //     ships with).
        //   - Light/dark theme is driven by the `data-theme` attribute on
        //     <html>, which github-markdown-css honors via its
        //     `[data-theme="dark"]` selectors.
        //   - highlight.js styles two stylesheets that we toggle via the
        //     `disabled` attribute when the theme changes.
        //   - We disable hyphenation and rely on browser word-wrapping so
        //     code blocks (which already overflow) and long URLs render
        //     consistently with GitHub.
        return """
        <!doctype html>
        <html lang="en" data-color-mode="auto" data-light-theme="light" data-dark-theme="dark">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(githubMarkdownCSS)
        </style>
        <style id="hljs-light">
        \(highlightLightCSS)
        </style>
        <style id="hljs-dark" disabled>
        \(highlightDarkCSS)
        </style>
        <style>
        :root { color-scheme: light dark; }
        html, body {
          margin: 0;
          padding: 0;
          background: transparent;
          /* Allow the whole document to be selected as one continuous range. */
          -webkit-user-select: text;
          user-select: text;
        }
        body {
          /* Match GitHub's reading column padding for a docs-y feel while
             still letting the panel use full width on narrow splits. */
          padding: 18px 28px 32px 28px;
        }
        .markdown-body {
          background: transparent;
          /* GitHub uses 16px on github.com for body text; keep that exact
             metric so headings, line-height, and spacing match. */
          font-size: 15px;
          /* The package sets max-width via wrapper class on github.com; we
             let it span the panel and just cap it to a comfortable reading
             width on very wide splits. */
          max-width: 980px;
          margin: 0 auto;
        }
        /* Fenced code blocks: github-markdown-css already styles `pre`; we
           add highlight.js's hljs class so the syntax theme applies. */
        .markdown-body pre code.hljs {
          padding: 16px;
          background: transparent;
          font-size: 13.5px;
          line-height: 1.5;
        }
        .markdown-body pre {
          padding: 0; /* hljs class already pads */
          overflow: auto;
        }
        /* Mermaid + Vega-Lite blocks. Both libs render into these containers
           lazily; the .cmux-source <pre> holds the raw block source for the
           library to read, hidden from view. */
        .cmux-mermaid, .cmux-vega {
          display: block;
          margin: 0.6em 0 0.9em 0;
          overflow-x: auto;
          text-align: center;
        }
        .cmux-mermaid svg, .cmux-vega canvas, .cmux-vega svg {
          max-width: 100%;
          height: auto;
        }
        .cmux-mermaid .cmux-source, .cmux-vega .cmux-source { display: none; }
        .markdown-body code[data-cmux-file] {
          cursor: default;
          border-bottom: 1px dotted var(--fgColor-muted);
        }
        .markdown-body code[data-cmux-file][data-cmux-file-exists="1"] {
          cursor: pointer;
          color: var(--fgColor-accent);
          border-bottom-color: var(--fgColor-accent);
        }
        .markdown-body a[data-cmux-file-exists="1"]::after,
        .markdown-body code[data-cmux-file][data-cmux-file-exists="1"]::after {
          content: " ↗";
          font-size: 0.82em;
          opacity: 0.65;
        }
        .cmux-frontmatter {
          margin: 0 0 16px 0;
          border: 1px solid var(--borderColor-default);
          border-radius: 6px;
          background: var(--bgColor-muted);
          color: var(--fgColor-muted);
        }
        .cmux-frontmatter summary {
          cursor: pointer;
          display: flex;
          align-items: center;
          gap: 6px;
          padding: 7px 10px;
          font-size: 12px;
          font-weight: 600;
          user-select: none;
        }
        .cmux-frontmatter summary::-webkit-details-marker {
          display: none;
        }
        .cmux-frontmatter summary::before {
          content: "▸";
          font-size: 10px;
          opacity: 0.75;
        }
        .cmux-frontmatter[open] summary {
          border-bottom: 1px solid var(--borderColor-default);
        }
        .cmux-frontmatter[open] summary::before {
          content: "▾";
        }
        .cmux-frontmatter pre {
          margin: 0;
          padding: 0;
          background: transparent;
          border-radius: 0;
        }
        .cmux-frontmatter pre code.hljs {
          padding: 10px 12px;
          background: transparent;
          font-size: 12.5px;
          line-height: 1.45;
        }
        .cmux-render-error {
          color: #f85149;
          font-family: ui-monospace, "SF Mono", Menlo, monospace;
          font-size: 12.5px;
          white-space: pre-wrap;
          padding: 8px 12px;
          border: 1px solid #f85149;
          border-radius: 6px;
          margin: 0.6em 0;
          text-align: left;
        }
        /* Custom selection color that reads on both themes. */
        ::selection { background: rgba(56, 139, 253, 0.4); }
        /* Smooth-anchor scroll for heading links. */
        html { scroll-behavior: smooth; }
        /* Loading shimmer while the first render is in flight. */
        #content:empty::before {
          content: "";
          display: block;
          height: 1px;
        }
        </style>
        </head>
        <body>
        <article id="content" class="markdown-body"><p style="color:#f85149">Loading markdown shell…</p></article>
        <script>
        \(markedJS)
        </script>
        <script>
        \(highlightJS)
        </script>
        <script>
        (function() {
          var contentEl = document.getElementById('content');
          var lightSheet = document.getElementById('hljs-light');
          var darkSheet  = document.getElementById('hljs-dark');
          function showBootError(message) {
            if (!contentEl) { return; }
            contentEl.textContent = '';
            var pre = document.createElement('pre');
            pre.style.color = '#f85149';
            pre.style.whiteSpace = 'pre-wrap';
            pre.textContent = 'Markdown viewer error: ' + String(message);
            contentEl.appendChild(pre);
          }
          window.onerror = function(message, source, lineno, colno, error) {
            showBootError((error && error.stack) || message);
          };
          window.onunhandledrejection = function(ev) {
            showBootError((ev.reason && ev.reason.stack) || ev.reason || 'unhandled rejection');
          };
          if (!window.marked || !window.hljs) {
            showBootError('marked/highlight libraries did not load');
          }

          function escapeHtml(s) {
            // Let WebKit's HTML serializer do escaping rather than trying
            // to keep a hand-written entity table correct.
            var div = document.createElement('div');
            div.textContent = String(s == null ? '' : s);
            return div.innerHTML;
          }

          function escapeDataAttribute(s) {
            // Store raw local paths in data attributes as percent-encoded
            // strings. This avoids attribute-escaping footguns entirely.
            return encodeURIComponent(String(s == null ? '' : s));
          }

          function unescapeDataAttribute(s) {
            try { return decodeURIComponent(String(s || '')); }
            catch (e) { return String(s || ''); }
          }

          function stripQueryFragment(path) {
            var s = String(path || '');
            var qi = s.indexOf('?');
            var hi = s.indexOf('#');
            var cut = -1;
            if (qi >= 0 && hi >= 0) { cut = Math.min(qi, hi); }
            else if (qi >= 0) { cut = qi; }
            else if (hi >= 0) { cut = hi; }
            return cut >= 0 ? s.slice(0, cut) : s;
          }
          function isMarkdownPathLike(path) {
            var s = stripQueryFragment(path).trim();
            if (!s) { return false; }
            var colon = s.indexOf(':');
            if (colon > 0) {
              var scheme = s.slice(0, colon).toLowerCase();
              if (scheme !== 'file') { return false; }
            }
            var slash = Math.max(s.lastIndexOf('/'), s.lastIndexOf('\\\\'));
            var leaf = slash >= 0 ? s.slice(slash + 1) : s;
            var dot = leaf.lastIndexOf('.');
            if (dot < 0) { return false; }
            var ext = leaf.slice(dot + 1).toLowerCase();
            return ext === 'md' || ext === 'markdown' || ext === 'mkd' || ext === 'mdx';
          }

          function extractFrontmatter(markdown) {
            var source = String(markdown == null ? '' : markdown).replace(/^\\uFEFF/, '');
            var match = source.match(/^---[ \\t]*\\r?\\n([\\s\\S]*?)\\r?\\n(?:---|\\.\\.\\.)[ \\t]*(?:\\r?\\n|$)/);
            if (!match) {
              return { frontmatter: '', body: source };
            }
            return {
              frontmatter: match[1] || '',
              body: source.slice(match[0].length)
            };
          }

          function renderFrontmatter(frontmatter) {
            var raw = String(frontmatter || '');
            if (!raw.trim()) { return ''; }
            var highlighted;
            try {
              if (hljs.getLanguage('yaml')) {
                highlighted = hljs.highlight(raw, { language: 'yaml', ignoreIllegals: true }).value;
              } else {
                highlighted = escapeHtml(raw);
              }
            } catch (e) {
              highlighted = escapeHtml(raw);
            }
            return '<details class="cmux-frontmatter">'
              + '<summary><span>Show frontmatter</span></summary>'
              + '<pre><code class="hljs language-yaml">' + highlighted + '</code></pre>'
              + '</details>';
          }

          function compactForProtocolCheck(value) {
            var raw = String(value || '');
            var out = '';
            for (var i = 0; i < raw.length; i++) {
              var code = raw.charCodeAt(i);
              if (code <= 32 || code === 127) { continue; }
              out += raw.charAt(i).toLowerCase();
            }
            return out;
          }

          function isSafeURLAttribute(name, value) {
            var raw = String(value || '').trim();
            if (!raw) { return true; }

            // Reject before URL parsing so whitespace-obfuscated active
            // protocols do not get normalized into something executable.
            var compact = compactForProtocolCheck(raw);
            if (
              compact.indexOf('javascript:') === 0 ||
              compact.indexOf('vbscript:') === 0 ||
              compact.indexOf('data:') === 0
            ) {
              return false;
            }

            try {
              var parsed = new URL(raw, document.baseURI || window.location.href);
              var protocol = (parsed.protocol || '').toLowerCase();
              if (name === 'href') {
                return protocol === 'http:' ||
                  protocol === 'https:' ||
                  protocol === 'file:' ||
                  protocol === 'mailto:' ||
                  protocol === 'tel:';
              }
              return protocol === 'http:' || protocol === 'https:' || protocol === 'file:';
            } catch (e) {
              return false;
            }
          }

          function sanitizeRenderedHTML(html) {
            var template = document.createElement('template');
            template.innerHTML = String(html || '');

            var blockedTags = {
              script: true,
              iframe: true,
              object: true,
              embed: true,
              link: true,
              meta: true,
              base: true,
              form: true,
              button: true,
              textarea: true,
              select: true,
              option: true,
              svg: true,
              math: true
            };

            var walker = document.createTreeWalker(template.content, NodeFilter.SHOW_ELEMENT);
            var elements = [];
            while (walker.nextNode()) {
              elements.push(walker.currentNode);
            }

            elements.forEach(function(el) {
              var tag = String(el.tagName || '').toLowerCase();
              if (blockedTags[tag]) {
                el.remove();
                return;
              }

              if (tag === 'input') {
                var inputType = String(el.getAttribute('type') || '').toLowerCase();
                if (inputType !== 'checkbox') {
                  el.remove();
                  return;
                }
                Array.prototype.slice.call(el.attributes || []).forEach(function(attr) {
                  var name = String(attr.name || '').toLowerCase();
                  if (name !== 'type' && name !== 'checked' && name !== 'disabled') {
                    el.removeAttribute(attr.name);
                  }
                });
                el.setAttribute('disabled', '');
                return;
              }

              Array.prototype.slice.call(el.attributes || []).forEach(function(attr) {
                var name = String(attr.name || '').toLowerCase();
                if (
                  name.indexOf('on') === 0 ||
                  name === 'style' ||
                  name === 'srcdoc' ||
                  name === 'autofocus' ||
                  name === 'formaction' ||
                  name === 'xlink:href'
                ) {
                  el.removeAttribute(attr.name);
                  return;
                }
                if ((name === 'href' || name === 'src') && !isSafeURLAttribute(name, attr.value)) {
                  el.removeAttribute(attr.name);
                }
              });

              if (tag === 'a') {
                el.setAttribute('rel', 'noopener noreferrer');
              }
            });

            return template.innerHTML;
          }

          // Configure marked: GitHub-flavored, with custom renderers for
          // code (syntax-highlighted via highlight.js), headings (with
          // GitHub-style slug ids for anchor links), and local markdown file
          // detection in inline code spans.
          // Note: when customizing via `marked.use({renderer})`, marked
          // calls these methods with the *legacy* positional signature
          // (text, level, raw / code, lang, escaped / href, title, text)
          // — NOT a single token object. Inline children are already
          // rendered to HTML and passed in as `text`.
          marked.use({
            gfm: true,
            breaks: false,
            pedantic: false,
            renderer: {
              codespan(code) {
                var raw = code || '';
                if (isMarkdownPathLike(raw)) {
                  return '<code data-cmux-file="' + escapeDataAttribute(raw) + '">' + escapeHtml(raw) + '</code>';
                }
                return '<code>' + escapeHtml(raw) + '</code>';
              },
              code(code, infostring, escaped) {
                var raw = code || '';
                var langMatch = (infostring || '').match(/^[A-Za-z0-9_+\\-.]+/);
                var langName = langMatch ? langMatch[0].toLowerCase() : '';

                // Mermaid: ```mermaid ... ``` -> div the lib will swap with SVG.
                if (langName === 'mermaid') {
                  return '<div class="cmux-mermaid"><pre class="cmux-source">'
                    + escapeHtml(raw)
                    + '</pre></div>\\n';
                }
                // Vega / Vega-Lite: ```vega-lite ... ``` (also vega, vegalite).
                if (langName === 'vega' || langName === 'vega-lite' || langName === 'vegalite') {
                  var vegaMode = (langName === 'vega') ? 'vega' : 'vega-lite';
                  return '<div class="cmux-vega" data-vega-mode="' + vegaMode + '">'
                    + '<pre class="cmux-source">' + escapeHtml(raw) + '</pre></div>\\n';
                }

                var highlighted;
                try {
                  if (langName && hljs.getLanguage(langName)) {
                    highlighted = hljs.highlight(raw, { language: langName, ignoreIllegals: true }).value;
                  } else {
                    highlighted = hljs.highlightAuto(raw).value;
                  }
                } catch (e) {
                  highlighted = escapeHtml(raw);
                }
                var langClass = langName ? ' language-' + langName : '';
                return '<pre><code class="hljs' + langClass + '">' + highlighted + '</code></pre>\\n';
              },
              heading(text, level, raw) {
                var slug = String(raw || '').toLowerCase()
                  .replace(/[^\\w\\- ]+/g, '')
                  .replace(/\\s+/g, '-')
                  .replace(/^-+|-+$/g, '');
                return '<h' + level + ' id="' + slug + '">' + text + '</h' + level + '>\\n';
              }
            }
          });

          // Lazy-loader: ask Swift to ship a library only when a document
          // actually contains a block that needs it.
          var libState = {};   // name -> 'pending' | 'ready'
          var libQueue = {};   // name -> [callbacks]
          function loadLib(name, cb) {
            if (libState[name] === 'ready') { cb(); return; }
            (libQueue[name] = libQueue[name] || []).push(cb);
            if (libState[name] !== 'pending') {
              libState[name] = 'pending';
              try {
                window.webkit.messageHandlers.cmuxLib.postMessage({ lib: name });
              } catch (e) {
                libState[name] = undefined;
                renderLibError(name, 'bridge unavailable');
              }
            }
          }
          window.__cmuxLibLoaded = function(name) {
            libState[name] = 'ready';
            var q = libQueue[name] || [];
            libQueue[name] = [];
            q.forEach(function(cb) { try { cb(); } catch (e) { /* ignore */ } });
          };

          function renderLibError(libName, msg) {
            var sel = libName === 'mermaid' ? '.cmux-mermaid' : '.cmux-vega';
            contentEl.querySelectorAll(sel + ':not([data-rendered])').forEach(function(el) {
              el.setAttribute('data-rendered', '1');
              el.innerHTML = '<div class="cmux-render-error">' + libName + ': ' + escapeHtml(msg) + '</div>';
            });
          }

          var mermaidInitialized = false;
          function renderMermaidBlocks() {
            if (typeof mermaid === 'undefined') { renderLibError('mermaid', 'library missing'); return; }
            try {
              if (!mermaidInitialized) {
                mermaid.initialize({
                  startOnLoad: false,
                  theme: darkMql.matches ? 'dark' : 'default',
                  securityLevel: 'strict',
                  fontFamily: 'ui-sans-serif, -apple-system, BlinkMacSystemFont, sans-serif'
                });
                mermaidInitialized = true;
              }
            } catch (e) { /* ignore reinit failure */ }

            var blocks = contentEl.querySelectorAll('.cmux-mermaid:not([data-rendered])');
            Array.prototype.forEach.call(blocks, function(el, i) {
              el.setAttribute('data-rendered', '1');
              var srcEl = el.querySelector('.cmux-source');
              var src = srcEl ? srcEl.textContent : el.textContent;
              var id = 'cmux-mermaid-' + Date.now() + '-' + i + '-' + Math.floor(Math.random() * 1e6);
              try {
                mermaid.render(id, src).then(function(res) {
                  el.innerHTML = res.svg;
                  if (res.bindFunctions) { try { res.bindFunctions(el); } catch (e) {} }
                }).catch(function(err) {
                  el.innerHTML = '<div class="cmux-render-error">Mermaid: '
                    + escapeHtml(String((err && err.message) || err)) + '</div>';
                });
              } catch (err) {
                el.innerHTML = '<div class="cmux-render-error">Mermaid: '
                  + escapeHtml(String((err && err.message) || err)) + '</div>';
              }
            });
          }

          function renderVegaBlocks() {
            if (typeof vegaEmbed === 'undefined') { renderLibError('vega-lite', 'library missing'); return; }
            var isDark = darkMql.matches;
            var blocks = contentEl.querySelectorAll('.cmux-vega:not([data-rendered])');
            Array.prototype.forEach.call(blocks, function(el) {
              el.setAttribute('data-rendered', '1');
              var srcEl = el.querySelector('.cmux-source');
              var raw = srcEl ? srcEl.textContent : el.textContent;
              var mode = el.getAttribute('data-vega-mode') === 'vega' ? 'vega' : 'vega-lite';
              try {
                var spec = JSON.parse(raw);
                el.innerHTML = '';
                var opts = { mode: mode, actions: false, renderer: 'canvas' };
                if (isDark) { opts.theme = 'dark'; }
                vegaEmbed(el, spec, opts).catch(function(err) {
                  el.innerHTML = '<div class="cmux-render-error">Vega: '
                    + escapeHtml(String((err && err.message) || err)) + '</div>';
                });
              } catch (e) {
                el.innerHTML = '<div class="cmux-render-error">Vega spec: '
                  + escapeHtml(String((e && e.message) || e)) + '</div>';
              }
            });
          }

          function postProcessSpecialBlocks() {
            if (contentEl.querySelector('.cmux-mermaid:not([data-rendered])')) {
              loadLib('mermaid', renderMermaidBlocks);
            }
            if (contentEl.querySelector('.cmux-vega:not([data-rendered])')) {
              loadLib('vega-lite', renderVegaBlocks);
            }
            markMarkdownFileLinks();
          }

          // Local markdown file links and inline-code spans.
          // Resolution is lazy: hover/focus asks Swift whether the path exists
          // relative to the current markdown file (and PWD fallback). Click
          // opens a new cmux markdown tab when it resolves.
          var mdFileResolveCache = {}; // raw path -> { exists, path }
          var mdFileResolvePending = {}; // requestId -> { rawPath, elements }
          var mdFileRequestSeq = 0;

          function markdownCandidateForElement(el) {
            if (!el) { return null; }
            if (el.matches && el.matches('code[data-cmux-file]')) {
              return unescapeDataAttribute(el.getAttribute('data-cmux-file'));
            }
            if (el.matches && el.matches('a[href]')) {
              var href = el.getAttribute('href') || '';
              if (isMarkdownPathLike(href)) { return href; }
            }
            return null;
          }

          function applyResolvedMarkdownFile(rawPath, result, elements) {
            mdFileResolveCache[rawPath] = result;
            (elements || []).forEach(function(el) {
              if (!el) { return; }
              el.setAttribute('data-cmux-file-checked', '1');
              if (result && result.exists) {
                el.setAttribute('data-cmux-file-exists', '1');
                el.setAttribute('title', 'Open markdown file: ' + result.path);
              } else {
                el.removeAttribute('data-cmux-file-exists');
              }
            });
          }

          function resolveMarkdownCandidate(el, openAfterResolve) {
            var rawPath = markdownCandidateForElement(el);
            if (!rawPath) { return false; }
            var cached = mdFileResolveCache[rawPath];
            if (cached) {
              applyResolvedMarkdownFile(rawPath, cached, [el]);
              if (openAfterResolve && cached.exists) { openMarkdownCandidate(rawPath); }
              return cached.exists;
            }
            var requestId = 'mdfile-' + (++mdFileRequestSeq);
            mdFileResolvePending[requestId] = { rawPath: rawPath, elements: [el], openAfterResolve: !!openAfterResolve };
            try {
              window.webkit.messageHandlers.cmuxLib.postMessage({
                action: 'resolveMarkdownFile',
                requestId: requestId,
                path: rawPath
              });
            } catch (e) { /* no bridge */ }
            return false;
          }

          window.__cmuxMarkdownFileResolved = function(result) {
            var pending = result && mdFileResolvePending[result.requestId];
            if (!pending) { return; }
            delete mdFileResolvePending[result.requestId];
            applyResolvedMarkdownFile(pending.rawPath, result, pending.elements);
            if (pending.openAfterResolve && result.exists) {
              openMarkdownCandidate(pending.rawPath);
            }
          };

          function openMarkdownCandidate(rawPath) {
            try {
              window.webkit.messageHandlers.cmuxLib.postMessage({ action: 'openMarkdownFile', path: rawPath });
            } catch (e) { /* no bridge */ }
          }

          function markMarkdownFileLinks() {
            contentEl.querySelectorAll('a[href]').forEach(function(a) {
              var href = a.getAttribute('href') || '';
              if (isMarkdownPathLike(href)) {
                a.setAttribute('data-cmux-file-candidate', href);
                // Eagerly resolve visible markdown links so the user gets
                // immediate affordance; inline code spans remain lazy-on-hover.
                resolveMarkdownCandidate(a, false);
              }
            });
          }

          contentEl.addEventListener('mouseover', function(ev) {
            var el = ev.target && ev.target.closest && ev.target.closest('code[data-cmux-file], a[href]');
            if (el) { resolveMarkdownCandidate(el, false); }
          });
          contentEl.addEventListener('focusin', function(ev) {
            var el = ev.target && ev.target.closest && ev.target.closest('code[data-cmux-file], a[href]');
            if (el) { resolveMarkdownCandidate(el, false); }
          });
          contentEl.addEventListener('click', function(ev) {
            var el = ev.target && ev.target.closest && ev.target.closest('code[data-cmux-file], a[href]');
            var rawPath = markdownCandidateForElement(el);
            if (!rawPath) { return; }
            // For markdown-looking paths, always stop WebKit navigation first.
            // If resolution fails, the click is intentionally a no-op rather
            // than loading raw file:// text into the viewer or opening a browser.
            ev.preventDefault();
            ev.stopPropagation();
            // Do not require the hover/resolve cache to be warm. Swift's
            // openMarkdownFile action resolves and no-ops for missing files,
            // so click can be deterministic and immediate.
            openMarkdownCandidate(rawPath);
          }, true);

          window.__cmuxRenderMarkdown = function(md) {
            try {
              var documentParts = extractFrontmatter(md || '');
              var html = renderFrontmatter(documentParts.frontmatter)
                + sanitizeRenderedHTML(marked.parse(documentParts.body || ''));
              if (contentEl.innerHTML !== html) {
                contentEl.innerHTML = html;
              }
              postProcessSpecialBlocks();
            } catch (e) {
              contentEl.innerHTML =
                '<div style="color:#f85149;font-family:ui-monospace,monospace;white-space:pre-wrap;padding:8px 12px;border:1px solid #f85149;border-radius:6px;margin-bottom:12px">'
                + 'markdown render error: ' + escapeHtml(String((e && e.message) || e))
                + '</div><pre><code>' + escapeHtml(md || '') + '</code></pre>';
            }
          };

          window.__cmuxRenderedHTML = function() {
            return contentEl ? contentEl.innerHTML : '';
          };

          var darkMql = window.matchMedia('(prefers-color-scheme: dark)');
          window.__cmuxApplyTheme = function() {
            var isDark = darkMql.matches;
            if (lightSheet && darkSheet) {
              lightSheet.disabled = !!isDark;
              darkSheet.disabled  = !isDark;
            }
            // Mermaid caches its theme; force re-init on next render so
            // freshly added diagrams pick up the new palette.
            mermaidInitialized = false;
          };
          if (darkMql.addEventListener) {
            darkMql.addEventListener('change', window.__cmuxApplyTheme);
          } else if (darkMql.addListener) {
            darkMql.addListener(window.__cmuxApplyTheme);
          }
          window.__cmuxApplyTheme();
        })();
        </script>
        </body>
        </html>
        """
    }
}
