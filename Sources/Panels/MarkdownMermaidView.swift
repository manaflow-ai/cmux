import AppKit
import SwiftUI
import WebKit

struct MarkdownMermaidHTMLDocument {
    static let mermaidScriptURL = "https://cdn.jsdelivr.net/npm/mermaid@10.9.3/dist/mermaid.min.js"
    static let mermaidScriptIntegrity = "sha384-R63zfMfSwJF4xCR11wXii+QUsbiBIdiDzDbtxia72oGWfkT7WHJfmD/I/eeHPJyT"

    static func isMermaidLanguage(_ language: String?) -> Bool {
        language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: " ")
            .first == "mermaid"
    }

    static func html(source: String, isDark: Bool) -> String {
        let scriptNonce = UUID().uuidString
        let sourceLiteral = javaScriptStringLiteral(source)
        let themeLiteral = javaScriptStringLiteral(isDark ? "dark" : "default")
        let foreground = isDark ? "#e8e8e8" : "#202020"
        let errorBackground = isDark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.04)"
        let errorBorder = isDark ? "rgba(255,255,255,0.18)" : "rgba(0,0,0,0.16)"
        let contentSecurityPolicy = "default-src 'none'; script-src 'nonce-\(scriptNonce)' https://cdn.jsdelivr.net; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'none'; base-uri 'none'; form-action 'none'"

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
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
        <script nonce="\(scriptNonce)" src="\(Self.mermaidScriptURL)" integrity="\(Self.mermaidScriptIntegrity)" crossorigin="anonymous"></script>
        <script nonce="\(scriptNonce)">
        const diagramSource = \(sourceLiteral);
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
            const mermaid = window.mermaid;
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

struct MarkdownMermaidDiagramView: View {
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
