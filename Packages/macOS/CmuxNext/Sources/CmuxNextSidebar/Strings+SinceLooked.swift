import Foundation

/// The hover card's "Since you looked" line (Resources/Localizable.xcstrings).
extension Strings {
    static func sinceLooked(_ parts: String) -> String {
        String(localized: "sidebar.sinceLooked.line", defaultValue: "Since you looked: \(parts)", bundle: .l10n)
    }
    static func sinceLookedDone(_ count: Int) -> String {
        String(localized: "sidebar.sinceLooked.done", defaultValue: "Done: \(count)", bundle: .l10n)
    }
    static func sinceLookedAsked(_ count: Int) -> String {
        String(localized: "sidebar.sinceLooked.asked", defaultValue: "Asked: \(count)", bundle: .l10n)
    }
    static func sinceLookedFailed(_ count: Int) -> String {
        String(localized: "sidebar.sinceLooked.failed", defaultValue: "Failed: \(count)", bundle: .l10n)
    }
}
