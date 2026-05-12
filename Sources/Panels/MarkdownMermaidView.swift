import AppKit
import MarkdownUI
import SwiftUI
import WebKit

nonisolated enum MarkdownCodeBlockLanguage {
    static func isMermaid(_ language: String?) -> Bool {
        guard let firstToken = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first else {
            return false
        }
        return firstToken.lowercased() == "mermaid"
    }
}

struct MarkdownCodeBlockView: View {
    let configuration: CodeBlockConfiguration
    let isDark: Bool

    var body: some View {
        if MarkdownCodeBlockLanguage.isMermaid(configuration.language) {
            MarkdownMermaidDiagramBlock(
                source: configuration.content,
                theme: isDark ? .dark : .default
            )
        } else {
            MarkdownDefaultCodeBlock(configuration: configuration, isDark: isDark)
        }
    }
}

private struct MarkdownDefaultCodeBlock: View {
    let configuration: CodeBlockConfiguration
    let isDark: Bool

    var body: some View {
        MarkdownCodeBlockShell(isDark: isDark) {
            configuration.label
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(13)
                    ForegroundColor(MarkdownCodeBlockPalette.foreground(isDark: isDark))
                }
        }
        .markdownMargin(top: 8, bottom: 8)
    }
}

private struct MarkdownRawCodeBlock: View {
    let content: String
    let isDark: Bool

    var body: some View {
        MarkdownCodeBlockShell(isDark: isDark) {
            Text(content)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(MarkdownCodeBlockPalette.foreground(isDark: isDark))
                .textSelection(.enabled)
        }
    }
}

private struct MarkdownCodeBlockShell<Content: View>: View {
    let isDark: Bool
    let content: Content

    init(isDark: Bool, @ViewBuilder content: () -> Content) {
        self.isDark = isDark
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            content
                .padding(12)
        }
        .background(MarkdownCodeBlockPalette.background(isDark: isDark))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private enum MarkdownCodeBlockPalette {
    static func foreground(isDark: Bool) -> Color {
        isDark
            ? Color(red: 0.9, green: 0.9, blue: 0.9)
            : Color(red: 0.2, green: 0.2, blue: 0.2)
    }

    static func background(isDark: Bool) -> Color {
        isDark
            ? Color(nsColor: NSColor(white: 0.08, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.93, alpha: 1.0))
    }
}

nonisolated enum MarkdownMermaidTheme: String, Equatable, Sendable {
    case `default`
    case dark

    var mermaidName: String { rawValue }
}

private struct MarkdownMermaidDiagramBlock: View {
    let source: String
    let theme: MarkdownMermaidTheme

    @State private var renderedHeight: CGFloat = 160
    @State private var errorState: MarkdownMermaidErrorState?

    var body: some View {
        Group {
            if let errorState, errorState.matches(source: source, theme: theme) {
                MarkdownMermaidErrorBlock(
                    message: errorState.message,
                    source: source,
                    isDark: theme == .dark
                )
            } else {
                MarkdownMermaidWebView(
                    source: source,
                    theme: theme,
                    renderedHeight: $renderedHeight,
                    onError: { message in
                        errorState = MarkdownMermaidErrorState(
                            source: source,
                            theme: theme,
                            message: message
                        )
                    }
                )
                .frame(maxWidth: .infinity, minHeight: 80)
                .frame(height: renderedHeight)
                .background(MarkdownMermaidPalette.background(theme: theme))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(MarkdownMermaidPalette.border(theme: theme), lineWidth: 1)
                }
            }
        }
        .markdownMargin(top: 8, bottom: 8)
        .onChange(of: source) { _, _ in
            errorState = nil
        }
        .onChange(of: theme) { _, _ in
            errorState = nil
        }
    }
}

private struct MarkdownMermaidErrorState: Equatable {
    let source: String
    let theme: MarkdownMermaidTheme
    let message: String

    func matches(source: String, theme: MarkdownMermaidTheme) -> Bool {
        self.source == source && self.theme == theme
    }
}

private struct MarkdownMermaidErrorBlock: View {
    let message: String
    let source: String
    let isDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .semibold))
                Text(String(localized: "markdown.mermaid.renderFailed", defaultValue: "Mermaid render failed"))
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(isDark ? Color(red: 1.0, green: 0.72, blue: 0.45) : Color(red: 0.62, green: 0.24, blue: 0.05))

            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(isDark ? .white.opacity(0.72) : .secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            MarkdownRawCodeBlock(content: source, isDark: isDark)
        }
        .padding(12)
        .background(MarkdownMermaidPalette.errorBackground(isDark: isDark))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(MarkdownMermaidPalette.errorBorder(isDark: isDark), lineWidth: 1)
        }
    }
}

private enum MarkdownMermaidPalette {
    static func background(theme: MarkdownMermaidTheme) -> Color {
        theme == .dark
            ? Color(nsColor: NSColor(white: 0.10, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.97, alpha: 1.0))
    }

    static func border(theme: MarkdownMermaidTheme) -> Color {
        theme == .dark
            ? Color.white.opacity(0.12)
            : Color.gray.opacity(0.25)
    }

    static func errorBackground(isDark: Bool) -> Color {
        isDark
            ? Color(red: 0.18, green: 0.12, blue: 0.10)
            : Color(red: 1.0, green: 0.96, blue: 0.92)
    }

    static func errorBorder(isDark: Bool) -> Color {
        isDark
            ? Color(red: 1.0, green: 0.52, blue: 0.32).opacity(0.35)
            : Color(red: 0.78, green: 0.32, blue: 0.14).opacity(0.35)
    }
}

private struct MarkdownMermaidWebView: NSViewRepresentable {
    let source: String
    let theme: MarkdownMermaidTheme
    @Binding var renderedHeight: CGFloat
    let onError: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(renderedHeight: $renderedHeight, onError: onError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: MarkdownMermaidHTMLDocument.handlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(source: source, theme: theme, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.renderedHeight = $renderedHeight
        context.coordinator.onError = onError
        context.coordinator.load(source: source, theme: theme, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: MarkdownMermaidHTMLDocument.handlerName
        )
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var renderedHeight: Binding<CGFloat>
        var onError: @MainActor (String) -> Void
        private var currentRequest: MarkdownMermaidRenderRequest?
        private var currentRequestID = UUID().uuidString

        init(
            renderedHeight: Binding<CGFloat>,
            onError: @escaping @MainActor (String) -> Void
        ) {
            self.renderedHeight = renderedHeight
            self.onError = onError
        }

        func load(source: String, theme: MarkdownMermaidTheme, in webView: WKWebView) {
            let request = MarkdownMermaidRenderRequest(source: source, theme: theme)
            guard currentRequest != request else { return }
            currentRequest = request
            currentRequestID = UUID().uuidString
            renderedHeight.wrappedValue = 160
            webView.loadHTMLString(
                MarkdownMermaidHTMLDocument.html(source: source, theme: theme, requestID: currentRequestID),
                baseURL: Bundle.main.resourceURL
            )
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let event = MarkdownMermaidScriptEvent(body: message.body),
                  event.requestID == currentRequestID else {
                return
            }
            switch event {
            case .height(let height, _):
                renderedHeight.wrappedValue = min(max(CGFloat(height), 80), 4000)
            case .error(let message, _):
                onError(message)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}

nonisolated struct MarkdownMermaidRenderRequest: Equatable, Sendable {
    let source: String
    let theme: MarkdownMermaidTheme
}

nonisolated enum MarkdownMermaidScriptEvent: Equatable, Sendable {
    case height(Double, requestID: String)
    case error(String, requestID: String)

    var requestID: String {
        switch self {
        case .height(_, let requestID), .error(_, let requestID):
            requestID
        }
    }

    init?(body: Any) {
        guard let dictionary = body as? [String: Any],
              let type = dictionary["type"] as? String,
              let requestID = dictionary["requestID"] as? String else {
            return nil
        }
        switch type {
        case "height":
            guard let height = dictionary["height"] as? Double else { return nil }
            self = .height(height, requestID: requestID)
        case "error":
            guard let message = dictionary["message"] as? String else { return nil }
            self = .error(message, requestID: requestID)
        default:
            return nil
        }
    }
}

nonisolated enum MarkdownMermaidHTMLDocument {
    static let handlerName = "cmuxMermaid"
    static let scriptFileName = "mermaid.min.js"

    static func html(
        source: String,
        theme: MarkdownMermaidTheme,
        requestID: String = "cmux-mermaid-render"
    ) -> String {
        let sourceLiteral = javaScriptStringLiteral(source)
        let themeLiteral = javaScriptStringLiteral(theme.mermaidName)
        let handlerLiteral = javaScriptStringLiteral(handlerName)
        let requestIDLiteral = javaScriptStringLiteral(requestID)
        let diagramLabel = htmlAttribute(
            String(localized: "markdown.mermaid.diagramLabel", defaultValue: "Mermaid diagram")
        )
        let runtimeUnavailableLiteral = javaScriptStringLiteral(
            String(localized: "markdown.mermaid.runtimeUnavailable", defaultValue: "Mermaid runtime is unavailable.")
        )
        let unknownErrorLiteral = javaScriptStringLiteral(
            String(localized: "markdown.mermaid.unknownError", defaultValue: "Unknown Mermaid render error")
        )

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:;">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root { color-scheme: \(theme == .dark ? "dark" : "light"); }
            html, body {
              margin: 0;
              padding: 0;
              background: transparent;
              overflow: hidden;
              font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            }
            #diagram {
              box-sizing: border-box;
              width: 100%;
              padding: 14px;
            }
            #diagram svg {
              display: block;
              max-width: 100%;
              height: auto;
              margin: 0 auto;
            }
          </style>
          <script src="./\(scriptFileName)"></script>
        </head>
        <body>
          <div id="diagram" aria-label="\(diagramLabel)"></div>
          <script>
            const source = \(sourceLiteral);
            const theme = \(themeLiteral);
            const handler = \(handlerLiteral);
            const requestID = \(requestIDLiteral);
            const runtimeUnavailableMessage = \(runtimeUnavailableLiteral);
            const unknownErrorMessage = \(unknownErrorLiteral);
            const container = document.getElementById('diagram');

            function post(payload) {
              payload.requestID = requestID;
              window.webkit.messageHandlers[handler].postMessage(payload);
            }

            function reportHeight() {
              const height = Math.ceil(Math.max(
                document.documentElement.scrollHeight,
                document.body.scrollHeight,
                container.getBoundingClientRect().height
              ));
              post({ type: 'height', height });
            }

            function errorMessage(error) {
              if (!error) { return unknownErrorMessage; }
              if (typeof error === 'string') { return error; }
              return error.str || error.message || String(error);
            }

            async function render() {
              try {
                if (!window.mermaid) {
                  throw new Error(runtimeUnavailableMessage);
                }
                window.mermaid.initialize({
                  startOnLoad: false,
                  theme,
                  securityLevel: 'strict'
                });
                const result = await window.mermaid.render('cmux-mermaid-diagram', source);
                container.innerHTML = result.svg;
                if (typeof result.bindFunctions === 'function') {
                  result.bindFunctions(container);
                }
                requestAnimationFrame(reportHeight);
                if (window.ResizeObserver) {
                  new ResizeObserver(reportHeight).observe(container);
                }
              } catch (error) {
                post({ type: 'error', message: errorMessage(error) });
              }
            }

            render();
          </script>
        </body>
        </html>
        """
    }

    static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              var encoded = String(data: data, encoding: .utf8) else {
            assertionFailure("JSONSerialization unexpectedly failed for string literal encoding")
            return "\"\""
        }
        encoded.removeFirst()
        encoded.removeLast()
        return encoded
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: ">", with: "\\u003E")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func htmlAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
