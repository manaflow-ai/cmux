import Foundation

/// The hover card's "Since you looked" line (Resources/Localizable.xcstrings).
extension Strings {
    static func sinceLooked(_ parts: String) -> String {
        String(localized: "sidebar.sinceLooked.line", defaultValue: "Since you looked: \(parts)", bundle: .localizedModule)
    }
    static func sinceLookedDone(_ count: Int) -> String {
        String(localized: "sidebar.sinceLooked.done", defaultValue: "Done: \(count)", bundle: .localizedModule)
    }
    static func sinceLookedAsked(_ count: Int) -> String {
        String(localized: "sidebar.sinceLooked.asked", defaultValue: "Asked: \(count)", bundle: .localizedModule)
    }
    static func sinceLookedFailed(_ count: Int) -> String {
        String(localized: "sidebar.sinceLooked.failed", defaultValue: "Failed: \(count)", bundle: .localizedModule)
    }
}
