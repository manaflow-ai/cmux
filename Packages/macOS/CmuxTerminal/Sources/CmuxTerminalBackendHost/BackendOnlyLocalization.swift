internal import Foundation

func backendOnlyLocalizedString(
    _ key: StaticString,
    defaultValue: String.LocalizationValue
) -> String {
    String(localized: key, defaultValue: defaultValue, bundle: .module)
}
