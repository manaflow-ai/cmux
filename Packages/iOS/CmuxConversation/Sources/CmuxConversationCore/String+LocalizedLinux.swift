#if !canImport(Darwin)
import Foundation

// String(localized:defaultValue:bundle:) and String.LocalizationValue are Apple only. Without them (the
// Linux CI package build) the lookup reads the bundle directly, and an interpolated default value is
// already the final text. Apple builds use Foundation's initializer and never compile this.
extension String {
    init(localized key: StaticString, defaultValue: String, bundle: Bundle) {
        self = bundle.localizedString(forKey: "\(key)", value: defaultValue, table: nil)
    }
}
#endif
