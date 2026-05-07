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
        Task { @MainActor in
            guard let html = await renderer.renderedHTML() else { return }
            let text = await renderer.renderedText() ?? panel.content
            let pb = NSPasteboard.general
            pb.clearContents()
            // public.html for rich-text-aware targets (Notes, Mail, Pages, ...)
            // and a plain-text fallback so plain editors still receive content.
            pb.setString(html, forType: .html)
            pb.setString(text, forType: .string)
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
@MainActor
final class MarkdownWebRendererHandle {
    fileprivate weak var coordinator: MarkdownWebRenderer.Coordinator?

    func renderedHTML() async -> String? {
        guard let coordinator else { return nil }
        return await coordinator.renderedHTML()
    }

    func renderedText() async -> String? {
        guard let coordinator else { return nil }
        return await coordinator.renderedText()
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

    @MainActor
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

        func renderedHTML() async -> String? {
            guard let webView, isLoaded else { return nil }
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
