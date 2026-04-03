import SwiftUI
import WebKit

/// A SwiftUI view that renders Mermaid diagram code using mermaid.js inside a WKWebView.
///
/// The view loads a minimal HTML page with the bundled mermaid.min.js library,
/// renders the diagram to SVG, and communicates the rendered height back to
/// SwiftUI via WKScriptMessageHandler so the view sizes itself correctly
/// within the surrounding ScrollView.
struct MermaidRenderView: View {
    let code: String
    let isDarkMode: Bool

    @State private var contentHeight: CGFloat = 200

    var body: some View {
        MermaidWebView(
            code: code,
            isDarkMode: isDarkMode,
            contentHeight: $contentHeight
        )
        .frame(height: contentHeight)
    }
}

// MARK: - WKWebView wrapper

private struct MermaidWebView: NSViewRepresentable {
    let code: String
    let isDarkMode: Bool
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        let coordinator = context.coordinator

        // Use a weak wrapper to avoid the strong-reference retain cycle
        // between WKUserContentController and Coordinator.
        let handler = WeakScriptMessageHandler(delegate: coordinator)
        contentController.add(handler, name: "mermaidHeight")
        contentController.add(handler, name: "mermaidError")
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView

        // Use a non-private-API approach: set the WebView layer background
        // to clear and make the view layer-backed.
        webView.wantsLayer = true
        webView.layer?.backgroundColor = .clear
        webView.enclosingScrollView?.drawsBackground = false

        coordinator.lastCode = code
        coordinator.lastIsDarkMode = isDarkMode
        loadMermaid(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        // Only reload when the code or theme actually changed.
        if coordinator.lastCode != code || coordinator.lastIsDarkMode != isDarkMode {
            coordinator.lastCode = code
            coordinator.lastIsDarkMode = isDarkMode
            loadMermaid(in: webView)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "mermaidHeight")
        controller.removeScriptMessageHandler(forName: "mermaidError")
        coordinator.webView = nil
    }

    // MARK: - HTML Generation

    private func loadMermaid(in webView: WKWebView) {
        let html = buildHTML()
        webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
    }

    /// Builds a self-contained HTML page that renders the mermaid diagram.
    private func buildHTML() -> String {
        let theme = isDarkMode ? "dark" : "default"
        let bgColor = isDarkMode ? "#1f1f1f" : "#fafafa"

        let localizedErrorPrefix = String(
            localized: "markdown.mermaid.syntaxError",
            defaultValue: "Mermaid syntax error:"
        )
        let escapedErrorPrefix = localizedErrorPrefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        // Escape the mermaid code for safe embedding inside a JS template literal.
        // Also escape </script> to prevent premature script tag closure (XSS vector).
        let escapedCode = code
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "</script>", with: "<\\/script>", options: .caseInsensitive)

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                background: \(bgColor);
                padding: 12px;
            }
            #mermaid-container {
                width: 100%;
                overflow-x: auto;
            }
            #mermaid-container svg {
                display: block;
                margin: 0 auto;
                min-width: min-content;
            }
            .error-container {
                color: \(isDarkMode ? "#ff6b6b" : "#cc0000");
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 13px;
                padding: 12px;
                border: 1px solid \(isDarkMode ? "#552222" : "#ffcccc");
                border-radius: 6px;
                background: \(isDarkMode ? "#2a1515" : "#fff5f5");
                width: 100%;
                white-space: pre-wrap;
                word-break: break-word;
            }
        </style>
        </head>
        <body>
        <div id="mermaid-container"></div>
        <script src="mermaid.min.js"></script>
        <script>
            mermaid.initialize({
                startOnLoad: false,
                theme: '\(theme)',
                securityLevel: 'strict',
                fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif'
            });

            function reportHeight() {
                const height = document.documentElement.scrollHeight;
                window.webkit.messageHandlers.mermaidHeight.postMessage(height);
            }

            function scheduleHeightReport() {
                requestAnimationFrame(() => requestAnimationFrame(reportHeight));
            }

            async function renderDiagram() {
                const container = document.getElementById('mermaid-container');
                const code = `\(escapedCode)`;
                try {
                    const { svg, bindFunctions } = await mermaid.render('mermaid-diagram', code);
                    container.innerHTML = svg;
                    if (typeof bindFunctions === 'function') bindFunctions(container);
                    scheduleHeightReport();
                } catch (error) {
                    container.replaceChildren();
                    const errorNode = document.createElement('div');
                    errorNode.className = 'error-container';
                    errorNode.textContent = `\(escapedErrorPrefix)\n${error.message}`;
                    container.appendChild(errorNode);
                    scheduleHeightReport();
                    requestAnimationFrame(() => {
                        window.webkit.messageHandlers.mermaidError.postMessage(error.message);
                    });
                }
            }

            window.addEventListener('resize', scheduleHeightReport);
            renderDiagram();
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Weak Message Handler

    /// Weak wrapper to break the retain cycle between WKUserContentController
    /// and the Coordinator. WKUserContentController strongly retains its
    /// message handlers, so passing the coordinator directly causes a leak.
    private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
        weak var delegate: WKScriptMessageHandler?

        init(delegate: WKScriptMessageHandler) {
            self.delegate = delegate
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            delegate?.userContentController(userContentController, didReceive: message)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var lastCode: String?
        var lastIsDarkMode: Bool?
        weak var webView: WKWebView?
        @Binding var contentHeight: CGFloat

        init(contentHeight: Binding<CGFloat>) {
            _contentHeight = contentHeight
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "mermaidHeight":
                if let height = message.body as? Double, height > 0 {
                    DispatchQueue.main.async { [weak self] in
                        self?.contentHeight = CGFloat(height)
                    }
                }
            case "mermaidError":
                break
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Only allow the initial HTML load. Block all external navigation
            // so that clicking links in SVG diagrams doesn't navigate away.
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
            } else {
                if let url = navigationAction.request.url {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            }
        }
    }
}
