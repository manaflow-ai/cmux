import Foundation
import WebKit

/// Renders the in-place explanation shown when an embedded-browser navigation
/// is rejected by an effective URL allowlist.
struct BrowserURLAllowlistBlockedPage {
    let blockedURL: URL
    let isManaged: Bool

    /// Returns an origin-only label with credentials, paths, queries, and
    /// fragments removed before it reaches UI chrome.
    static func safeDisplayOrigin(for url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(), let host = url.host else {
            return ""
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.string ?? "\(scheme)://\(host)"
    }

    /// Loads the localized policy message into `webView`.
    @MainActor
    func load(in webView: WKWebView) {
        webView.loadHTMLString(Self.html(isManaged: isManaged), baseURL: nil)
    }

    /// Returns the localized title used by both the blocked page and browser chrome.
    static func title(isManaged: Bool) -> String {
        String(
            localized: isManaged
                ? "browser.error.urlAllowlist.title"
                : "browser.error.urlAllowlist.userTitle",
            defaultValue: isManaged
                ? "Blocked by your organization's policy"
                : "Blocked by the embedded-browser URL policy"
        )
    }

    private static func html(isManaged: Bool) -> String {
        let title = Self.title(isManaged: isManaged)
        let message = String(
            localized: isManaged
                ? "browser.error.urlAllowlist.message"
                : "browser.error.urlAllowlist.userMessage",
            defaultValue: isManaged
                ? "This URL is not allowed by your organization's embedded-browser policy."
                : "This URL is not allowed by the embedded-browser URL policy."
        )
        let escapedTitle = escape(title)
        let escapedMessage = escape(message)
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
          <h1>\(escapedTitle)</h1>
          <p>\(escapedMessage)</p>
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
