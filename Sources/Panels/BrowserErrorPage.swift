import Foundation
import WebKit

struct BrowserErrorPage {
    let failedURL: String
    let failedRequest: URLRequest?
    let error: NSError
    let sslBypassState: BrowserSSLTrustBypassState

    func load(in webView: WKWebView) {
        let content = BrowserErrorPageContent(error: error, failedURL: failedURL)

        let escapedTitle = escapeHTML(content.title)
        let escapedMessage = escapeHTML(content.message)
        let escapedURL = escapeHTML(failedURL)
        let escapedReloadLabel = escapeHTML(String(localized: "browser.error.reload", defaultValue: "Reload"))
        let escapedBypassLabel = escapeHTML(String(localized: "browser.error.bypass", defaultValue: "Proceed Anyway (Unsafe)"))

        let bypassButtonHTML: String
        if content.permitsSSLBypass,
           let failedRequest,
           let bypassURL = sslBypassState.createPendingBypassAction(for: failedRequest) {
            let token = URLComponents(url: bypassURL, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "token" }?
                .value ?? ""
            let escapedToken = escapeHTML(token)
            let escapedBypassURL = escapeHTML(bypassURL.absoluteString)
            let escapedBypassOnClick = escapeHTML(Self.bypassOnClickScript)
            bypassButtonHTML = """
                <button class="button bypass" type="button" data-token="\(escapedToken)" data-action-url="\(escapedBypassURL)" onclick="\(escapedBypassOnClick)">\(escapedBypassLabel)</button>
            """
        } else {
            bypassButtonHTML = ""
        }

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width">
        <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            display: flex; align-items: center; justify-content: center;
            min-height: 80vh; margin: 0; padding: 20px;
            background: #1a1a1a; color: #e0e0e0;
        }
        .container { text-align: center; max-width: 420px; }
        h1 { font-size: 18px; font-weight: 600; margin-bottom: 8px; }
        p { font-size: 13px; color: #999; line-height: 1.5; }
        .url { font-size: 12px; color: #666; word-break: break-all; margin-top: 16px; }
        button, a.button {
            margin-top: 20px; padding: 6px 20px;
            background: #333; color: #e0e0e0; border: 1px solid #555;
            border-radius: 6px; font-size: 13px; cursor: pointer;
            text-decoration: none; display: inline-block;
        }
        button:hover, a.button:hover { background: #444; }
        .bypass {
            background: transparent; border: 1px solid #c0392b; color: #c0392b; margin-left: 10px;
        }
        .bypass:hover { background: rgba(192, 57, 43, 0.1); }
        @media (prefers-color-scheme: light) {
            body { background: #fafafa; color: #222; }
            p { color: #666; }
            .url { color: #999; }
            button, a.button { background: #eee; color: #222; border-color: #ccc; }
            button:hover, a.button:hover { background: #ddd; }
            .bypass { border-color: #c0392b; color: #c0392b; }
            .bypass:hover { background: rgba(192, 57, 43, 0.1); }
        }
        </style>
        </head>
        <body>
        <div class="container">
            <h1>\(escapedTitle)</h1>
            <p>\(escapedMessage)</p>
            <div class="url">\(escapedURL)</div>
            <button onclick="location.reload()">\(escapedReloadLabel)</button>\(bypassButtonHTML)
        </div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: failedURL))
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let bypassOnClickScript = """
    var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(BrowserSSLTrustBypassMessageHandler.name);
    if (handler) {
        handler.postMessage(this.dataset.token);
    } else {
        window.location.href = this.dataset.actionUrl;
    }
    """
}
