import Foundation

public struct CmuxConfigValidationLocalization {
    public init() {}
    public func string(
        _ key: StaticString,
        defaultValue: String
    ) -> String {
        String(localized: key, defaultValue: String.LocalizationValue(stringLiteral: defaultValue), bundle: .module)
    }

    public func format(
        _ key: StaticString,
        defaultValue: String,
        _ arguments: any CVarArg...
    ) -> String {
        let localized = string(key, defaultValue: defaultValue)
        return String(format: localized, locale: Locale.current, arguments: arguments)
    }
}
