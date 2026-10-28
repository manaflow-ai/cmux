import Foundation

public struct CmuxConfigValidationLocalization {
    public init() {}
    public func string(
        _ key: StaticString,
        defaultValue: String
    ) -> String {
        CmuxFoundationLocalization.string(key, defaultValue: defaultValue)
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
