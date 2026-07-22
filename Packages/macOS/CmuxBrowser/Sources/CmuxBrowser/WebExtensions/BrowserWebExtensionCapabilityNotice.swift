/// A product limitation that must be disclosed before installation.
public enum BrowserWebExtensionCapabilityNotice: String, Codable, Equatable, Sendable {
    /// The extension runs in browser-only mode without its desktop app bridge.
    case browserOnlyNoDesktopBridge

    /// Native messaging and containing-app group access are unavailable in cmux.
    case nativeAppIntegrationUnavailable
}
