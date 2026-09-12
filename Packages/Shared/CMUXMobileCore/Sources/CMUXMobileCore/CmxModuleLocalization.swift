import Foundation

/// Shared module-bundle localization bridge for transport value types.
extension String {
    /// Resolves a localized module string from a static key and fallback.
    static func cmxModuleLocalized(
        _ key: StaticString,
        defaultValue: String
    ) -> String {
        String(
            localized: key,
            defaultValue: String.LocalizationValue(defaultValue),
            bundle: .module
        )
    }
}
