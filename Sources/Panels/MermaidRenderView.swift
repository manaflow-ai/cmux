import SwiftUI
import WebKit

/// A SwiftUI view that renders Mermaid diagram code using mermaid.js inside a WKWebView.
///
/// The view loads a minimal HTML page with the bundled mermaid.min.js library,
/// renders the diagram to SVG, and communicates the rendered height back to
/// SwiftUI via WKScriptMessageHandler so the view sizes itself correctly
/// within the surrounding ScrollView.
struct MermaidRenderView: NSViewRepresentable {
    let code: String
    let isDarkMode: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "mermaidHeight")
        contentController.add(context.coordinator, name: "mermaidError")
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        // Transparent background to blend with the markdown panel.
        webView.setValue(false, forKey: "drawsBackground")

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

    // MARK: - HTML Generation

    private func loadMermaid(in webView: WKWebView) {
        let html = buildHTML()
        webView.loadHTMLString(html, baseURL: mermaidJSBaseURL())
    }

    /// Returns the base URL pointing to the Resources directory so the
    /// HTML page can load the bundled mermaid.min.js via a relative path.
    private func mermaidJSBaseURL() -> URL? {
        Bundle.main.resourceURL
    }

    /// Builds a self-contained HTML page that renders the mermaid diagram.
    private func buildHTML() -> String {
        let theme = isDarkMode ? "dark" : "default"
        let bgColor = isDarkMode ? "#1f1f1f" : "#fafafa"

        // Escape the mermaid code for safe embedding inside a JS template literal.
        let escapedCode = code
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

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
                display: flex;
                justify-content: center;
                align-items: flex-start;
                padding: 12px;
                overflow: hidden;
            }
            #mermaid-container {
                width: 100%;
                display: flex;
                justify-content: center;
            }
            #mermaid-container svg {
                max-width: 100%;
                height: auto;
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
                securityLevel: 'loose',
                fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif'
            });

            async function renderDiagram() {
                const container = document.getElementById('mermaid-container');
                const code = `\(escapedCode)`;
                try {
                    const { svg } = await mermaid.render('mermaid-diagram', code);
                    container.innerHTML = svg;

                    // Wait for the SVG to layout, then report the height.
                    requestAnimationFrame(() => {
                        const height = document.body.scrollHeight;
                        window.webkit.messageHandlers.mermaidHeight.postMessage(height);
                    });
                } catch (error) {
                    container.innerHTML = '<div class="error-container">Mermaid syntax error:\\n' +
                        error.message.replace(/</g, '&lt;').replace(/>/g, '&gt;') +
                        '</div>';
                    requestAnimationFrame(() => {
                        const height = document.body.scrollHeight;
                        window.webkit.messageHandlers.mermaidHeight.postMessage(height);
                        window.webkit.messageHandlers.mermaidError.postMessage(error.message);
                    });
                }
            }

            renderDiagram();
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var lastCode: String?
        var lastIsDarkMode: Bool?
        weak var webView: WKWebView?

        /// Called by mermaid.js to report the rendered SVG height.
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "mermaidHeight":
                if let height = message.body as? CGFloat, height > 0 {
                    DispatchQueue.main.async { [weak self] in
                        guard let webView = self?.webView else { return }
                        let constraint = webView.heightAnchor.constraint(equalToConstant: height)
                        // Remove any previously installed height constraint.
                        webView.constraints
                            .filter { $0.firstAttribute == .height && $0.firstItem === webView }
                            .forEach { webView.removeConstraint($0) }
                        constraint.isActive = true
                        webView.invalidateIntrinsicContentSize()
                    }
                }
            case "mermaidError":
                // Error is already displayed inline in the WebView.
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
