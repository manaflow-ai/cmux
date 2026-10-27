import Foundation

/// cmux: MessagesLab's one string bundle (catalyst Layout.swift's `MessagesLabLocalization`,
/// which is in the MessagesLabHome module, not this one), for the vendored sidebar files.
/// It is this module's own bundle, which holds `SidebarLocalizable`, so no string reads the
/// app's main bundle. A constant: the row renderers read it on every core.
enum MessagesLabLocalization {
    static let bundle = Bundle.module
    /// The string for `key` in the user's preferred language; `english` when it is missing.
    static func string(_ key: String, _ english: String, table: String? = nil) -> String {
        bundle.localizedString(forKey: key, value: english, table: table)
    }
}
