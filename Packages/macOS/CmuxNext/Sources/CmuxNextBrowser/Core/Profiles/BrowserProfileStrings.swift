import Foundation

/// Localized text of browser profiles (Resources/BrowserProfiles.xcstrings).
public nonisolated enum BrowserProfileStrings {
    /// Name of the built-in profile until the user renames it.
    public static var defaultName: String {
        String(localized: "browserProfile.defaultName", defaultValue: "Default", table: "BrowserProfiles", bundle: .localizedModule)
    }
}
