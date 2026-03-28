import Foundation

/// Which browser engine backs a profile or browser view.
public enum BrowserEngineType: String, Codable, Sendable {
    case webkit
    case chromium
}
