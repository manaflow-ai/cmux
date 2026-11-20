import Foundation

/// cmux: MessagesLab's one string bundle (catalyst Layout.swift's `MessagesLabLocalization`,
/// which is in the MessagesLabHome module, not this one), for the vendored sidebar files.
/// This module's own bundle holds `SidebarLocalizable`; it is the default, so no string
/// reads the app's main bundle even before a host sets it.
enum MessagesLabLocalization {
    private static let lock = NSLock()
    private static var current = Bundle.module
    static var bundle: Bundle {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    /// The string for `key` in the user's preferred language; `english` when it is missing.
    static func string(_ key: String, _ english: String, table: String? = nil) -> String {
        bundle.localizedString(forKey: key, value: english, table: table)
    }
}
