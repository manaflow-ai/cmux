import Foundation

/// Strings of Mac Screen tabs (Resources/Localizable.xcstrings).
nonisolated enum L {
    static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
