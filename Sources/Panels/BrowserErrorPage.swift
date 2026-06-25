import Foundation
import WebKit

@MainActor
enum BrowserErrorPageRetry {
    case urlOnly
    case request(URLRequest)
    case disabled
}

@MainActor
struct BrowserErrorPage {
    let failedURL: String
    let retry: BrowserErrorPageRetry
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
        if let retryURL = Self.retryURL(from: failedURL, retry: retry) {
            reloadControlHTML = """
                <a class="button reload" href="\(escapeHTML(retryURL.absoluteString))">\(escapedReloadLabel)</a>
            """
        } else {
            reloadControlHTML = ""
        }

        let bypassButtonHTML: String
        if content.permitsSSLBypass,
           case let .request(failedRequest) = retry,
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
            --border: rgba(0, 0, 0, 0.12);
            --text: #1d1d1f;
            --secondary: #666a70;
            --tertiary: #80858c;
            --code-background: rgba(0, 0, 0, 0.045);
            --secondary-background-hover: rgba(0, 0, 0, 0.055);
            --focus-ring: rgba(29, 29, 31, 0.22);
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
            padding: 0;
            text-align: left;
        }

        .icon {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            width: 28px;
            height: 28px;
            margin-bottom: 14px;
            border: 1px solid var(--border);
            border-radius: 50%;
            color: var(--secondary);
            font-size: 16px;
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
            background: var(--text);
            color: var(--background);
        }

        .reload:hover {
            opacity: 0.86;
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
                --border: rgba(255, 255, 255, 0.14);
                --text: #f5f5f7;
                --secondary: #a1a1a6;
                --tertiary: #8e8e93;
                --code-background: rgba(255, 255, 255, 0.07);
                --secondary-background-hover: rgba(255, 255, 255, 0.08);
                --focus-ring: rgba(245, 245, 247, 0.24);
            }
        }

        @media (max-width: 420px) {
            body {
                padding: 20px;
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

    static func retryURL(from failedURL: String, retry: BrowserErrorPageRetry = .urlOnly) -> URL? {
        switch retry {
        case .disabled:
            return nil
        case .request(let failedRequest):
            guard failedRequest.browserCanReloadWithURLOnly else {
                return nil
            }
        case .urlOnly:
            break
        }
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
