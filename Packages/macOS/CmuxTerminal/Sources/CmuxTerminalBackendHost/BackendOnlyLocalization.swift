internal import Foundation

enum BackendOnlyLocalization {
    static func string(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .module)
    }
}
