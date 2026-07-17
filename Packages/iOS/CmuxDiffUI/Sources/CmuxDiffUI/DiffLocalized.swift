import Foundation

struct DiffLocalized: Sendable {
    func string(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .module)
    }

    func format(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        _ arguments: any CVarArg...
    ) -> String {
        String(format: string(key, defaultValue: defaultValue), arguments: arguments)
    }
}
