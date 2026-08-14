import Foundation

extension CmuxAgentManifestCodec {
    /// Resolves user-facing manifest diagnostics from the host app's catalog.
    static func localizedReason(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(localized: key, defaultValue: defaultValue)
    }

    /// Resolves and formats a user-facing manifest diagnostic.
    static func localizedReason(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        arguments: [any CVarArg]
    ) -> String {
        let format = String(localized: key, defaultValue: defaultValue)
        return String(format: format, locale: .current, arguments: arguments)
    }
}
