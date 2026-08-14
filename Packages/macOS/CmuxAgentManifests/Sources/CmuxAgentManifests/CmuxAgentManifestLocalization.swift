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

    /// Resolves and formats one localized loader message.
    static func reason(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        arguments: [any CVarArg]
    ) -> String {
        let format = String(localized: key, defaultValue: defaultValue)
        return String(format: format, locale: .current, arguments: arguments)
    }
}
