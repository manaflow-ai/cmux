import Foundation

public enum CmuxConfigValidationLocalization {
    public static func string(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .module)
    }

    public static func format(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        _ arguments: any CVarArg...
    ) -> String {
        let localized = string(key, defaultValue: defaultValue)
        return String(format: localized, locale: Locale.current, arguments: arguments)
    }
}
