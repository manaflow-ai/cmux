import Foundation

/// The Mac Screen module's strings (`Localizable.xcstrings` in this target).
struct MacScreenStrings {
    func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}

let L = MacScreenStrings()
