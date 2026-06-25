import Foundation
import WebKit

@MainActor
struct BrowserErrorPage {
    let failedURL: String
    let failedRequest: URLRequest?
    let error: NSError
    let sslBypassState: BrowserSSLTrustBypassState

    @discardableResult
    func load(in webView: WKWebView) -> Bool {
        let content = BrowserErrorPageContent(error: error, failedURL: failedURL)

        let escapedTitle = escapeHTML(content.title)
        let escapedMessage = escapeHTML(content.message)
        let escapedURL = escapeHTML(failedURL)
        let escapedReloadLabel = escapeHTML(String(localized: "browser.error.reload", defaultValue: "Reload"))
        let escapedBypassLabel = escapeHTML(String(localized: "browser.error.bypass", defaultValue: "Proceed Anyway (Unsafe)"))
        let reloadControlHTML: String
        if let retryURL = Self.retryURL(from: failedURL) {
            reloadControlHTML = """
                <a class="button reload" href="\(escapeHTML(retryURL.absoluteString))">\(escapedReloadLabel)</a>
            """
        } else {
            reloadControlHTML = """
                <button class="button reload" type="button" onclick="location.reload()">\(escapedReloadLabel)</button>
            """
        }

        let bypassButtonHTML: String
        if content.permitsSSLBypass,
           let failedRequest,
           let bypassURL = sslBypassState.createPendingBypassAction(for: failedRequest) {
            let token = URLComponents(url: bypassURL, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "token" }?
                .value ?? ""
            let escapedToken = escapeHTML(token)
            let escapedBypassOnClick = escapeHTML(Self.bypassOnClickScript)
            bypassButtonHTML = """
                <button class="button bypass" type="button" data-token="\(escapedToken)" onclick="\(escapedBypassOnClick)">\(escapedBypassLabel)</button>
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
        :root {
            color-scheme: light dark;
            --background: #f7f7f8;
            --surface: #ffffff;
            --border: rgba(0, 0, 0, 0.12);
            --text: #1d1d1f;
            --secondary: #666a70;
            --tertiary: #80858c;
            --code-background: rgba(0, 0, 0, 0.045);
            --primary-background: #1d1d1f;
            --primary-background-hover: #343437;
            --primary-text: #ffffff;
            --secondary-background-hover: rgba(0, 0, 0, 0.055);
            --focus-ring: rgba(0, 122, 255, 0.32);
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            box-sizing: border-box;
            margin: 0;
            padding: 32px;
            background: var(--background);
            color: var(--text);
            -webkit-font-smoothing: antialiased;
            text-rendering: optimizeLegibility;
        }

        .container {
            width: min(520px, 100%);
            box-sizing: border-box;
            padding: 28px;
            border: 1px solid var(--border);
            border-radius: 8px;
            background: var(--surface);
            box-shadow: 0 12px 34px rgba(0, 0, 0, 0.08);
            text-align: left;
        }

        .icon {
            margin-bottom: 14px;
            color: var(--secondary);
            font-size: 22px;
            font-weight: 700;
            line-height: 1;
        }

        h1 {
            margin: 0;
            font-size: 22px;
            font-weight: 650;
            line-height: 1.2;
            letter-spacing: 0;
        }

        p {
            margin: 10px 0 0;
            font-size: 14px;
            color: var(--secondary);
            line-height: 1.5;
        }

        .url {
            margin-top: 18px;
            padding: 10px 12px;
            border-radius: 6px;
            background: var(--code-background);
            color: var(--tertiary);
            direction: ltr;
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
            font-size: 12px;
            line-height: 1.45;
            overflow-wrap: anywhere;
            word-break: break-word;
        }

        .actions {
            display: flex;
            flex-wrap: wrap;
            gap: 10px;
            margin-top: 24px;
        }

        .button {
            min-height: 34px;
            box-sizing: border-box;
            padding: 7px 16px;
            border: 1px solid transparent;
            border-radius: 6px;
            font: inherit;
            font-size: 13px;
            font-weight: 600;
            line-height: 1.35;
            cursor: pointer;
            text-decoration: none;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            transition: background-color 120ms ease, border-color 120ms ease, color 120ms ease;
        }

        .reload {
            background: var(--primary-background);
            color: var(--primary-text);
        }

        .reload:hover {
            background: var(--primary-background-hover);
        }

        .bypass {
            background: transparent;
            border-color: var(--border);
            color: var(--text);
        }

        .bypass:hover {
            background: var(--secondary-background-hover);
        }

        .button:focus-visible {
            outline: 3px solid var(--focus-ring);
            outline-offset: 2px;
        }

        @media (prefers-color-scheme: dark) {
            :root {
                --background: #1c1c1e;
                --surface: #242426;
                --border: rgba(255, 255, 255, 0.14);
                --text: #f5f5f7;
                --secondary: #a1a1a6;
                --tertiary: #8e8e93;
                --code-background: rgba(255, 255, 255, 0.07);
                --primary-background: #f5f5f7;
                --primary-background-hover: #ffffff;
                --primary-text: #1d1d1f;
                --secondary-background-hover: rgba(255, 255, 255, 0.08);
            }
        }

        @media (max-width: 420px) {
            body {
                padding: 20px;
            }

            .container {
                padding: 22px;
            }

            .button {
                width: 100%;
            }
        }
        </style>
        </head>
        <body>
        <div class="container">
            <div class="icon" aria-hidden="true">!</div>
            <h1>\(escapedTitle)</h1>
            <p>\(escapedMessage)</p>
            <div class="url">\(escapedURL)</div>
            <div class="actions">\(reloadControlHTML)\(bypassButtonHTML)</div>
        </div>
        </body>
        </html>
        """
        // Keep token-bearing interstitials out of the failed site's origin.
        webView.loadHTMLString(html, baseURL: nil)
        return !bypassButtonHTML.isEmpty
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func retryURL(from failedURL: String) -> URL? {
        guard let url = URL(string: failedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            return nil
        }
        return url
    }

    private static let bypassOnClickScript = """
    var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(BrowserSSLTrustBypassMessageHandler.name);
    if (handler) {
        handler.postMessage(this.dataset.token);
    }
    """
}
