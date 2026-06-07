internal import Foundation

struct MobileDiagnosticsL10n {
    private init() {}

    static func string(_ key: StaticString, defaultValue: String) -> String {
        #if canImport(Darwin)
        String(localized: key, defaultValue: String.LocalizationValue(defaultValue), bundle: .main)
        #else
        defaultValue
        #endif
    }

    static func format(
        _ key: StaticString,
        defaultValue: String,
        _ arguments: any CVarArg...
    ) -> String {
        String(
            format: string(key, defaultValue: defaultValue),
            locale: Locale.current,
            arguments: arguments
        )
    }
}
