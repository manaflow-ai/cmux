import Foundation

/// Resolves loader diagnostics from the host application's string catalog.
struct CmuxAgentManifestLocalization: Sendable {
    /// Resolves one localized loader message.
    static func reason(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(localized: key, defaultValue: defaultValue)
    }
}
