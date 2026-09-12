public import Foundation

/// An unpacked extension cannot be loaded safely; the path and remedy are
/// included so configuration errors can be corrected without debug logs.
public struct ChromiumExtensionError: Error, LocalizedError, Sendable {
    /// The configured extension directory.
    public let path: String
    /// A localized explanation of what must be corrected.
    public let reason: String

    /// Creates an actionable extension failure.
    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    /// Localized diagnostic including the extension directory.
    public var errorDescription: String? {
        String.localizedStringWithFormat(
            String(localized: "browser.chromium.extensions.invalid",
                   defaultValue: "Could not load extension at %@: %@. Fix browser.extensionDirectories and reopen the pane.", bundle: .module),
            path, reason
        )
    }
}
