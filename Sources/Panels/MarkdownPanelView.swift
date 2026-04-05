import AppKit
import SwiftUI
import MarkdownUI
import WebKit

/// SwiftUI view that renders a MarkdownPanel's content using MarkdownUI.
struct MarkdownPanelView: View {
    @ObservedObject var panel: MarkdownPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(MarkdownRendererSettings.useWebViewKey)
    private var useWebView = MarkdownRendererSettings.defaultUseWebView

    var body: some View {
        Group {
            if panel.isFileUnavailable {
                fileUnavailableView
            } else if useWebView {
                markdownWebViewContent
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
        .overlay {
            if isVisibleInUI {
                // Observe left-clicks without intercepting them so markdown text
                // selection and link activation continue to use the native path.
                MarkdownPointerObserver(onPointerDown: onRequestPanelFocus)
            }
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
    }

    // MARK: - WebView Content

    private var markdownWebViewContent: some View {
        VStack(spacing: 0) {
            filePathHeader
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 16)

            MarkdownWebViewRepresentable(
                content: panel.content,
                colorScheme: colorScheme
            )
        }
    }

    // MARK: - Native MarkdownUI Content

    private var markdownContentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // File path breadcrumb
                filePathHeader
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                Divider()
                    .padding(.horizontal, 16)

                // Rendered markdown
                Markdown(panel.content)
                    .markdownTheme(cmuxMarkdownTheme)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
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
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }

    private var cmuxMarkdownTheme: Theme {
        let isDark = colorScheme == .dark

        return Theme()
            // Text
            .text {
                ForegroundColor(isDark ? .white.opacity(0.9) : .primary)
                FontSize(14)
            }
            // Headings
            .heading1 { configuration in
                VStack(alignment: .leading, spacing: 8) {
                    configuration.label
                        .markdownTextStyle {
                            FontWeight(.bold)
                            FontSize(28)
                            ForegroundColor(isDark ? .white : .primary)
                        }
                    Divider()
                }
                .markdownMargin(top: 24, bottom: 16)
            }
            .heading2 { configuration in
                VStack(alignment: .leading, spacing: 6) {
                    configuration.label
                        .markdownTextStyle {
                            FontWeight(.bold)
                            FontSize(22)
                            ForegroundColor(isDark ? .white : .primary)
                        }
                    Divider()
                }
                .markdownMargin(top: 20, bottom: 12)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(18)
                        ForegroundColor(isDark ? .white : .primary)
                    }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading4 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(16)
                        ForegroundColor(isDark ? .white : .primary)
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading5 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.medium)
                        FontSize(14)
                        ForegroundColor(isDark ? .white : .primary)
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .heading6 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.medium)
                        FontSize(13)
                        ForegroundColor(isDark ? .white.opacity(0.7) : .secondary)
                    }
                    .markdownMargin(top: 8, bottom: 4)
            }
            // Code blocks
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(13)
                            ForegroundColor(isDark ? Color(red: 0.9, green: 0.9, blue: 0.9) : Color(red: 0.2, green: 0.2, blue: 0.2))
                        }
                        .padding(12)
                }
                .background(isDark
                    ? Color(nsColor: NSColor(white: 0.08, alpha: 1.0))
                    : Color(nsColor: NSColor(white: 0.93, alpha: 1.0)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: 8, bottom: 8)
            }
            // Inline code
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(13)
                ForegroundColor(isDark ? Color(red: 0.85, green: 0.6, blue: 0.95) : Color(red: 0.6, green: 0.2, blue: 0.7))
                BackgroundColor(isDark
                    ? Color(nsColor: NSColor(white: 0.18, alpha: 1.0))
                    : Color(nsColor: NSColor(white: 0.92, alpha: 1.0)))
            }
            // Block quotes
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isDark ? Color.white.opacity(0.2) : Color.gray.opacity(0.4))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(isDark ? .white.opacity(0.6) : .secondary)
                            FontSize(14)
                        }
                        .padding(.leading, 12)
                }
                .markdownMargin(top: 8, bottom: 8)
            }
            // Links
            .link {
                ForegroundColor(Color.accentColor)
            }
            // Strong
            .strong {
                FontWeight(.semibold)
            }
            // Tables
            .table { configuration in
                configuration.label
                    .markdownTableBorderStyle(.init(color: isDark ? .white.opacity(0.15) : .gray.opacity(0.3)))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            isDark
                                ? Color(nsColor: NSColor(white: 0.14, alpha: 1.0))
                                : Color(nsColor: NSColor(white: 0.96, alpha: 1.0)),
                            isDark
                                ? Color(nsColor: NSColor(white: 0.10, alpha: 1.0))
                                : Color(nsColor: NSColor(white: 1.0, alpha: 1.0))
                        )
                    )
                    .markdownMargin(top: 8, bottom: 8)
            }
            // Thematic break (horizontal rule)
            .thematicBreak {
                Divider()
                    .markdownMargin(top: 16, bottom: 16)
            }
            // List items
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 4)
            }
            // Paragraphs
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 8)
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

// MARK: - WebView-based Markdown Renderer

/// Renders markdown as HTML in a WKWebView for full multi-line text selection support.
struct MarkdownWebViewRepresentable: NSViewRepresentable {
    let content: String
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastContent: String?
        var lastIsDark: Bool?
    }

    func makeNSView(context: Context) -> CmuxWebView {
        let config = WKWebViewConfiguration()
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        let webView = CmuxWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        let isDark = colorScheme == .dark
        context.coordinator.lastContent = content
        context.coordinator.lastIsDark = isDark
        loadHTML(into: webView, isDark: isDark)
        return webView
    }

    func updateNSView(_ webView: CmuxWebView, context: Context) {
        let isDark = colorScheme == .dark
        let contentChanged = content != context.coordinator.lastContent
        let themeChanged = isDark != context.coordinator.lastIsDark
        guard contentChanged || themeChanged else { return }
        context.coordinator.lastContent = content
        context.coordinator.lastIsDark = isDark

        if themeChanged {
            // Theme change requires full HTML reload to update CSS variables.
            loadHTML(into: webView, isDark: isDark)
        } else {
            // Content-only change: update in-place via JS to preserve scroll position
            // and avoid WKWebView dropping rapid loadHTMLString calls.
            let escaped = Self.escapeForJS(content)
            let markdownContent = content
            webView.evaluateJavaScript(
                "document.getElementById('content').innerHTML = marked.parse(`\(escaped)`);"
            ) { _, error in
                if error != nil {
                    // JS evaluation failed (e.g., page not yet loaded); fall back to
                    // a full HTML reload to guarantee the content is rendered.
                    // Guard inside async to check staleness at execution time, not
                    // scheduling time — a newer updateNSView may run between the two.
                    DispatchQueue.main.async {
                        guard context.coordinator.lastContent == markdownContent,
                              context.coordinator.lastIsDark == isDark else { return }
                        let html = Self.wrapInHTML(markdown: markdownContent, isDark: isDark)
                        webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
                    }
                }
            }
        }
    }

    private func loadHTML(into webView: WKWebView, isDark: Bool) {
        let html = Self.wrapInHTML(markdown: content, isDark: isDark)
        webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
    }

    private static func escapeForJS(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "</", with: "<\\/")
    }

    static func wrapInHTML(markdown: String, isDark: Bool) -> String {
        let escapedMarkdown = escapeForJS(markdown)
        let bg = isDark ? "#1e1e1e" : "#fafafa"
        let fg = isDark ? "rgba(255,255,255,0.9)" : "#1a1a1a"
        let mutedFg = isDark ? "rgba(255,255,255,0.6)" : "#666"
        let codeBg = isDark ? "#141414" : "#ededed"
        let codeFg = isDark ? "#e6e6e6" : "#333"
        let inlineCodeFg = isDark ? "rgb(217,153,242)" : "rgb(153,51,179)"
        let inlineCodeBg = isDark ? "#2e2e2e" : "#eaeaea"
        let borderColor = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.12)"
        let tableBgEven = isDark ? "#1a1a1a" : "#fff"
        let tableBgOdd = isDark ? "#242424" : "#f5f5f5"
        let linkColor = isDark ? "#58a6ff" : "#0969da"
        let blockquoteBorder = isDark ? "rgba(255,255,255,0.2)" : "rgba(0,0,0,0.2)"

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="\(isDark ? "dark" : "light")">
        <style>
        * { box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-size: 14px;
            line-height: 1.6;
            color: \(fg);
            background: \(bg);
            padding: 16px 24px;
            margin: 0;
            -webkit-font-smoothing: antialiased;
        }
        h1 { font-size: 28px; font-weight: 700; margin: 24px 0 16px; padding-bottom: 8px; border-bottom: 1px solid \(borderColor); }
        h2 { font-size: 22px; font-weight: 700; margin: 20px 0 12px; padding-bottom: 6px; border-bottom: 1px solid \(borderColor); }
        h3 { font-size: 18px; font-weight: 600; margin: 16px 0 8px; }
        h4 { font-size: 16px; font-weight: 600; margin: 12px 0 6px; }
        h5 { font-size: 14px; font-weight: 500; margin: 10px 0 4px; }
        h6 { font-size: 13px; font-weight: 500; margin: 8px 0 4px; color: \(mutedFg); }
        p { margin: 4px 0 8px; }
        a { color: \(linkColor); text-decoration: none; }
        a:hover { text-decoration: underline; }
        strong { font-weight: 600; }
        code {
            font-family: "JetBrains Mono", "SF Mono", Menlo, monospace;
            font-size: 13px;
            color: \(inlineCodeFg);
            background: \(inlineCodeBg);
            padding: 2px 5px;
            border-radius: 3px;
        }
        pre {
            background: \(codeBg);
            border-radius: 6px;
            padding: 12px;
            overflow-x: auto;
            margin: 8px 0;
        }
        pre code {
            color: \(codeFg);
            background: none;
            padding: 0;
            font-size: 13px;
        }
        blockquote {
            border-left: 3px solid \(blockquoteBorder);
            margin: 8px 0;
            padding-left: 12px;
            color: \(mutedFg);
        }
        hr { border: none; border-top: 1px solid \(borderColor); margin: 16px 0; }
        ul, ol { padding-left: 24px; }
        li { margin: 4px 0; }
        table { border-collapse: collapse; margin: 8px 0; width: 100%; }
        th, td {
            border: 1px solid \(borderColor);
            padding: 6px 12px;
            text-align: left;
        }
        tr:nth-child(odd) td { background: \(tableBgOdd); }
        tr:nth-child(even) td { background: \(tableBgEven); }
        th { font-weight: 600; background: \(tableBgOdd); }
        img { max-width: 100%; }
        input[type="checkbox"] { margin-right: 6px; }
        </style>
        <script src="marked.min.js"></script>
        </head>
        <body>
        <div id="content"></div>
        <script>
        const md = `\(escapedMarkdown)`;
        marked.setOptions({ gfm: true, breaks: false });
        document.getElementById('content').innerHTML = marked.parse(md);
        </script>
        </body>
        </html>
        """
    }
}

// MARK: - Pointer Observer

private struct MarkdownPointerObserver: NSViewRepresentable {
    let onPointerDown: () -> Void

    func makeNSView(context: Context) -> MarkdownPanelPointerObserverView {
        let view = MarkdownPanelPointerObserverView()
        view.onPointerDown = onPointerDown
        return view
    }

    func updateNSView(_ nsView: MarkdownPanelPointerObserverView, context: Context) {
        nsView.onPointerDown = onPointerDown
    }
}

final class MarkdownPanelPointerObserverView: NSView {
    var onPointerDown: (() -> Void)?
    private var eventMonitor: Any?
    private weak var forwardedMouseTarget: NSView?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installEventMonitorIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard PaneFirstClickFocusSettings.isEnabled(),
              window?.isKeyWindow != true,
              bounds.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        forwardedMouseTarget = forwardedTarget(for: event)
        forwardedMouseTarget?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        forwardedMouseTarget?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        forwardedMouseTarget?.mouseUp(with: event)
        forwardedMouseTarget = nil
    }

    func shouldHandle(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown,
              let window,
              event.window === window,
              !isHiddenOrHasHiddenAncestor else { return false }
        if PaneFirstClickFocusSettings.isEnabled(), window.isKeyWindow != true {
            return false
        }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    func handleEventIfNeeded(_ event: NSEvent) -> NSEvent {
        guard shouldHandle(event) else { return event }
        DispatchQueue.main.async { [weak self] in
            self?.onPointerDown?()
        }
        return event
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleEventIfNeeded(event) ?? event
        }
    }

    private func forwardedTarget(for event: NSEvent) -> NSView? {
        guard let window else {
#if DEBUG
            NSLog("MarkdownPanelPointerObserverView.forwardedTarget skipped, window=0 contentView=0")
#endif
            return nil
        }
        guard let contentView = window.contentView else {
#if DEBUG
            NSLog("MarkdownPanelPointerObserverView.forwardedTarget skipped, window=1 contentView=0")
#endif
            return nil
        }
        isHidden = true
        defer { isHidden = false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        let target = contentView.hitTest(point)
        return target === self ? nil : target
    }
}
