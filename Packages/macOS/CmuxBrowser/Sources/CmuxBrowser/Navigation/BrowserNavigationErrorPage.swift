public import Foundation

/// Renders the dark-mode-aware HTML error page shown in a browser web view when
/// a navigation fails.
///
/// The page is a pure function of already-localized, already-resolved strings:
/// the app-side navigation delegate classifies the failure with
/// ``BrowserNavigationErrorKind``, resolves the localized title, message, and
/// reload-button label (`String(localized:)` stays app-side so the Japanese
/// binding is preserved), then calls ``html(title:message:failedURL:reloadLabel:)``
/// and hands the result to `WKWebView.loadHTMLString(_:baseURL:)`. All four
/// inputs are HTML-escaped here before interpolation into the template.
public struct BrowserNavigationErrorPage: Sendable {
    /// Builds the error-page HTML document.
    ///
    /// Each parameter is HTML-escaped (`&`, `<`, `>`, `"`) before it is
    /// interpolated into the template.
    ///
    /// - Parameters:
    ///   - title: The localized headline (e.g. "Can't reach this page").
    ///   - message: The localized explanatory body text.
    ///   - failedURL: The URL string that failed to load, shown beneath the
    ///     message.
    ///   - reloadLabel: The localized label for the reload button.
    /// - Returns: A complete HTML document string.
    public static func html(
        title: String,
        message: String,
        failedURL: String,
        reloadLabel: String
    ) -> String {
        let escapeHTML: (String) -> String = { value in
            value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }

        let escapedTitle = escapeHTML(title)
        let escapedMessage = escapeHTML(message)
        let escapedURL = escapeHTML(failedURL)
        let escapedReloadLabel = escapeHTML(reloadLabel)

        return """
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
        button {
            margin-top: 20px; padding: 6px 20px;
            background: #333; color: #e0e0e0; border: 1px solid #555;
            border-radius: 6px; font-size: 13px; cursor: pointer;
        }
        button:hover { background: #444; }
        @media (prefers-color-scheme: light) {
            body { background: #fafafa; color: #222; }
            p { color: #666; }
            .url { color: #999; }
            button { background: #eee; color: #222; border-color: #ccc; }
            button:hover { background: #ddd; }
        }
        </style>
        </head>
        <body>
        <div class="container">
            <h1>\(escapedTitle)</h1>
            <p>\(escapedMessage)</p>
            <div class="url">\(escapedURL)</div>
            <button onclick="location.reload()">\(escapedReloadLabel)</button>
        </div>
        </body>
        </html>
        """
    }
}
