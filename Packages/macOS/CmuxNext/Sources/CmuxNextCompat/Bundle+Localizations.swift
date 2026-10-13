public import Foundation

extension Bundle {
    /// The string for `key` in the first of `preferredLocalizations` that this bundle has, with the
    /// call shape of `localizedString(forKey:value:table:localizations:)` (macOS 15.4), so that
    /// cmux-next runs on macOS 14 (plans/cmux-next/macos-floor.md). macOS 15.4 and later use the
    /// system call. Below it, the best match of the bundle's `.lproj` directories answers; with no
    /// match that is the development localization (en).
    public func localizedString(forKey key: String, value: String?, table: String?,
                                preferredLocalizations: [String]) -> String {
        if #available(macOS 15.4, *) {
            return localizedString(forKey: key, value: value, table: table,
                                   localizations: preferredLocalizations.map(Locale.Language.init(identifier:)))
        }
        if let match = Bundle.preferredLocalizations(from: localizations, forPreferences: preferredLocalizations).first,
           let path = path(forResource: match, ofType: "lproj"), let localized = Bundle(path: path) {
            return localized.localizedString(forKey: key, value: value, table: table)
        }
        return localizedString(forKey: key, value: value, table: table)
    }
}
