import Foundation

/// A user's browser-engine selection policy.
public enum BrowserEnginePreference: String, Codable, CaseIterable, Sendable {
    /// Follow the engine family of the macOS default HTTP/HTTPS handler.
    case automatic = "auto"

    /// Always use Apple's WebKit engine.
    case webKit = "webkit"

    /// Always use a Chromium engine.
    case chromium
}
