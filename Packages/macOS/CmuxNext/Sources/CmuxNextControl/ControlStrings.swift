import CmuxNextCompat
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

    /// The refusal of a request line longer than `limit` bytes.
    static func requestTooLarge(limit: Int,
                                preferredLocalizations: [String] = Bundle.module.preferredLocalizations, locale: Locale = .current) -> String {
        bundle.localizedString(forKey: "control.error.requestTooLarge", value: "Request line exceeds %@", table: nil,
                               arguments: [.byteCount(Int64(clamping: limit))], preferredLocalizations: preferredLocalizations, locale: locale)
    }

    /// The refusal while `pending` requests wait in a queue that holds `limit`.
    static func busy(pending: Int, limit: Int,
                     preferredLocalizations: [String] = Bundle.module.preferredLocalizations, locale: Locale = .current) -> String {
        bundle.localizedString(forKey: "control.error.busy",
                               value: "cmux is busy (queued requests: %1$lld, limit %2$lld); retry later",
                               table: nil,
                               arguments: [.count(pending), .count(limit)], preferredLocalizations: preferredLocalizations, locale: locale)
    }
}
