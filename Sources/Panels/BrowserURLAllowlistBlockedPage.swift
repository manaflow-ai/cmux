import Foundation
import WebKit

/// Renders the in-place explanation shown when an embedded-browser navigation
/// is rejected by an effective URL allowlist.
@MainActor
struct BrowserURLAllowlistBlockedPage {
    let blockedURL: URL

    /// Loads the localized policy message into `webView`.
    func load(in webView: WKWebView) {
        webView.loadHTMLString(Self.html(for: blockedURL), baseURL: nil)
    }

    private static func html(for url: URL) -> String {
        let title = String(
            localized: "browser.error.urlAllowlist.title",
            defaultValue: "Blocked by your organization's policy"
        )
        let message = String(
            localized: "browser.error.urlAllowlist.message",
            defaultValue: "This URL is not allowed by your organization’s embedded-browser policy."
        )
        let attempted = String(
            localized: "browser.error.urlAllowlist.attemptedURL",
            defaultValue: "Attempted URL"
        )
        let escapedTitle = escape(title)
        let escapedMessage = escape(message)
        let escapedAttempted = escape(attempted)
        let escapedURL = escape(url.absoluteString)
        return """
        <!doctype html>
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          body { font: -apple-system-body; margin: 0; padding: 12vh 10vw; color: #666; }
          main { max-width: 680px; margin: auto; }
          h1 { color: #222; font-size: 24px; font-weight: 600; }
          p { font-size: 15px; line-height: 1.5; }
          code { display: block; margin-top: 18px; padding: 12px; overflow-wrap: anywhere;
                 border-radius: 8px; background: rgba(127,127,127,.14); color: #555; }
          @media (prefers-color-scheme: dark) { h1 { color: #eee; } code { color: #ddd; } }
        </style></head><body><main>
          <h1>(escapedTitle)</h1>
          <p>(escapedMessage)</p>
          <p>(escapedAttempted):</p>
          <code>(escapedURL)</code>
        </main></body></html>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
