import Foundation

/// The web-content engine that renders a cmux browser surface.
public enum BrowserEngineKind: String, Codable, CaseIterable, Sendable {
    /// Apple's WebKit engine hosted by `WKWebView`.
    case webKit = "webkit"

    /// A Chromium engine controlled through the Chrome DevTools Protocol.
    case chromium
}
