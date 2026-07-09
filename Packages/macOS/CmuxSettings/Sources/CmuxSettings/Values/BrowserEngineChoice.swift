import Foundation

/// Which engine renders cmux browser surfaces.
public enum BrowserEngineChoice: String, CaseIterable, Sendable, SettingCodable {
    /// System WebKit (`WKWebView`); the default.
    case webkit
    /// Embedded OWL Chromium runtime (experimental).
    case chromium
}
