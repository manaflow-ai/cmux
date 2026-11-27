#if !canImport(Darwin)
import Foundation

extension String {
    /// Linux stand-in for Foundation's `String(localized:defaultValue:...)`,
    /// which swift-corelibs-foundation does not provide. It looks `key` up in
    /// the bundle's compiled `.strings` tables and falls back to
    /// `defaultValue`; string catalogs (`.xcstrings`) are compiled only by
    /// Xcode, so on Linux the English default is what callers get.
    public init(
        localized key: StaticString,
        defaultValue: String,
        table: String? = nil,
        bundle: Bundle? = nil,
        locale: Locale = .current,
        comment: StaticString? = nil
    ) {
        self = (bundle ?? .main).localizedString(forKey: "\(key)", value: defaultValue, table: table)
    }
}
#endif
