import AppKit
import SwiftUI
import WebKit
import MarkdownUI

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

    // MARK: - Content

    private var markdownContentView: some View {
        let sourceDirectoryURL = panel.sourceDirectoryURL
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // File path breadcrumb
                filePathHeader
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                Divider()
                    .padding(.horizontal, 16)

                // Rendered markdown
                Markdown(panel.content, baseURL: sourceDirectoryURL, imageBaseURL: sourceDirectoryURL)
                    .markdownTheme(cmuxMarkdownTheme)
                    .markdownImageProvider(MarkdownPanelImageProvider(markdownDirectoryURL: sourceDirectoryURL))
                    .markdownInlineImageProvider(MarkdownPanelInlineImageProvider())
                    .textSelection(.enabled)
                    // Wire link activation through NSWorkspace explicitly.
                    // SwiftUI's default Link path does not fire reliably
                    // for the rendered Markdown in this panel; setting the
                    // env action makes it deterministic. Surface failures
                    // (no registered handler for the scheme, etc.) by
                    // returning .systemAction so the click is not silently
                    // swallowed.
                    .environment(\.openURL, OpenURLAction { url in
                        NSWorkspace.shared.open(url) ? .handled : .systemAction
                    })
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
                if MarkdownMermaidHTMLDocument.isMermaidLanguage(configuration.language) {
                    MarkdownMermaidDiagramView(source: configuration.content, isDark: isDark)
                        .markdownMargin(top: 8, bottom: 8)
                } else {
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

struct MarkdownPanelImageProvider: ImageProvider {
    let markdownDirectoryURL: URL

    func makeImage(url: URL?) -> some View {
        MarkdownPanelImageView(url: Self.resolvedImageURL(url, markdownDirectoryURL: markdownDirectoryURL))
    }

    static func resolvedImageURL(from source: String, markdownDirectoryURL: URL) -> URL? {
        guard let url = URL(string: source, relativeTo: markdownDirectoryURL) else { return nil }
        return resolvedImageURL(url, markdownDirectoryURL: markdownDirectoryURL)
    }

    static func resolvedImageURL(_ url: URL?, markdownDirectoryURL: URL) -> URL? {
        guard let url else { return nil }
        let absoluteURL = url.absoluteURL
        return absoluteURL.isFileURL ? absoluteURL.standardizedFileURL : absoluteURL
    }
}

struct MarkdownPanelInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        if url.isFileURL {
            guard let image = NSImage(contentsOf: url) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return Image(nsImage: image)
        }
        let provider: DefaultInlineImageProvider = .default
        return try await provider.image(with: url, label: label)
    }
}

private struct MarkdownPanelImageView: View {
    let url: URL?

    var body: some View {
        if let url {
            if url.isFileURL {
                localImage(url)
            } else {
                remoteImage(url)
            }
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private func localImage(_ url: URL) -> some View {
        if let image = NSImage(contentsOf: url) {
            fittedImage(Image(nsImage: image))
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func remoteImage(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                fittedImage(image)
            case .empty, .failure:
                Color.clear.frame(width: 0, height: 0)
            @unknown default:
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    private func fittedImage(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownMermaidHTMLDocument {
    private static let mermaidModuleURL = "https://cdn.jsdelivr.net/npm/mermaid@10.9.3/dist/mermaid.esm.min.mjs"

    static func isMermaidLanguage(_ language: String?) -> Bool {
        language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: " ")
            .first == "mermaid"
    }

    static func html(source: String, isDark: Bool) -> String {
        let sourceLiteral = javaScriptStringLiteral(source)
        let moduleURLLiteral = javaScriptStringLiteral(mermaidModuleURL)
        let themeLiteral = javaScriptStringLiteral(isDark ? "dark" : "default")
        let foreground = isDark ? "#e8e8e8" : "#202020"
        let errorBackground = isDark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.04)"
        let errorBorder = isDark ? "rgba(255,255,255,0.18)" : "rgba(0,0,0,0.16)"

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html, body {
          margin: 0;
          padding: 0;
          background: transparent;
          color: \(foreground);
          font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          overflow: hidden;
        }
        #diagram {
          box-sizing: border-box;
          min-width: 100%;
          padding: 12px;
        }
        #diagram svg {
          display: block;
          height: auto;
          max-width: 100%;
        }
        #error {
          box-sizing: border-box;
          margin: 0;
          padding: 12px;
          white-space: pre-wrap;
          word-break: break-word;
          border: 1px solid \(errorBorder);
          border-radius: 6px;
          background: \(errorBackground);
          font: 12px ui-monospace, SFMono-Regular, Menlo, monospace;
        }
        </style>
        </head>
        <body>
        <div id="diagram"></div>
        <pre id="error" hidden></pre>
        <script>
        const diagramSource = \(sourceLiteral);
        const mermaidModuleURL = \(moduleURLLiteral);
        const mermaidTheme = \(themeLiteral);

        const postHeight = () => {
          requestAnimationFrame(() => {
            const height = Math.ceil(Math.max(
              document.body.scrollHeight,
              document.documentElement.scrollHeight,
              document.body.getBoundingClientRect().height
            ));
            window.webkit?.messageHandlers?.cmuxMermaidHeight?.postMessage(height);
          });
        };

        const showError = (error) => {
          document.getElementById("diagram").hidden = true;
          const errorElement = document.getElementById("error");
          errorElement.hidden = false;
          errorElement.textContent = error?.message || String(error || "");
          postHeight();
        };

        const renderDiagram = async () => {
          try {
            const module = await import(mermaidModuleURL);
            const mermaid = module.default;
            mermaid.initialize({
              startOnLoad: false,
              theme: mermaidTheme,
              securityLevel: "strict"
            });
            const randomID = window.crypto?.randomUUID?.() || `${Date.now()}-${Math.random()}`;
            const renderID = "cmux-mermaid-" + randomID.replace(/[^A-Za-z0-9_]/g, "");
            const rendered = await mermaid.render(renderID, diagramSource);
            document.getElementById("diagram").innerHTML = rendered.svg;
            postHeight();
          } catch (error) {
            showError(error);
          }
        };

        window.addEventListener("resize", postHeight);
        renderDiagram();
        </script>
        </body>
        </html>
        """
    }

    private static func javaScriptStringLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: string, options: []),
              var literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        literal = literal
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: ">", with: "\\u003E")
            .replacingOccurrences(of: "&", with: "\\u0026")
        return literal
    }
}

private struct MarkdownMermaidDiagramView: View {
    let source: String
    let isDark: Bool
    @State private var height: Double = 160

    var body: some View {
        MarkdownMermaidWebView(source: source, isDark: isDark, height: $height)
            .frame(maxWidth: .infinity)
            .frame(height: boundedHeight)
            .background(isDark
                ? Color(nsColor: NSColor(white: 0.08, alpha: 1.0))
                : Color(nsColor: NSColor(white: 0.96, alpha: 1.0)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var boundedHeight: Double {
        min(max(height, 80), 2000)
    }
}

private struct MarkdownMermaidWebView: NSViewRepresentable {
    let source: String
    let isDark: Bool
    @Binding var height: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "cmuxMermaidHeight")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        if webView.responds(to: Selector(("setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.loadHTMLString(MarkdownMermaidHTMLDocument.html(source: source, isDark: isDark), baseURL: nil)
        context.coordinator.loadedSource = source
        context.coordinator.loadedIsDark = isDark
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedSource != source || context.coordinator.loadedIsDark != isDark else {
            return
        }
        context.coordinator.loadedSource = source
        context.coordinator.loadedIsDark = isDark
        webView.loadHTMLString(MarkdownMermaidHTMLDocument.html(source: source, isDark: isDark), baseURL: nil)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxMermaidHeight")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        @Binding private var height: Double
        var loadedSource: String?
        var loadedIsDark: Bool?

        init(height: Binding<Double>) {
            self._height = height
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "cmuxMermaidHeight" else { return }
            let rawHeight: Double?
            if let number = message.body as? NSNumber {
                rawHeight = number.doubleValue
            } else {
                rawHeight = message.body as? Double
            }
            guard let rawHeight else { return }
            let clampedHeight = min(max(rawHeight, 80), 2000)
            Task { @MainActor in
                height = clampedHeight
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("window.dispatchEvent(new Event('resize'));", completionHandler: nil)
        }
    }
}

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
