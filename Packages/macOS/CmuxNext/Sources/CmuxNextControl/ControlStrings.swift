import Foundation

/// Localized control-socket error messages and unsupported reasons. Keys live
/// in this module's Localizable.xcstrings (21 languages). Error codes,
/// method names, action ids, parameter names and handles are format
/// arguments or literal tokens, never translated; clients branch on
/// `ControlError.code`, not on the message.
enum ControlStrings {
    /// The bundle holding the compiled string table.
    static var bundle: Bundle { .module }

    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: bundle)
    }

    static func format(_ key: StaticString, _ value: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
        String(format: text(key, value), arguments: arguments)
    }
}
