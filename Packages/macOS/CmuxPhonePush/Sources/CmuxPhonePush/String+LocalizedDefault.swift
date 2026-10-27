#if !canImport(Darwin)
import Foundation

extension String {
    /// Apple's `String(localized:defaultValue:)` where Foundation lacks it (Linux): the main bundle's
    /// Localizable table, else `defaultValue`, the lookup Apple's initializer makes.
    init(localized key: StaticString, defaultValue: String) {
        self = Bundle.main.localizedString(forKey: "\(key)", value: defaultValue, table: nil)
    }
}
#endif
