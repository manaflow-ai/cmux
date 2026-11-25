import Foundation

/// Localized text of browser profiles (Resources/BrowserProfiles.xcstrings).
public nonisolated enum BrowserProfileStrings {
    /// Name of the built-in profile until the user renames it.
    public static var defaultName: String {
        String(localized: "browserProfile.defaultName", defaultValue: "Default", table: "BrowserProfiles", bundle: .module)
    }

    /// Omnibar badge tooltip and VoiceOver label.
    public static func badgeHelp(_ name: String) -> String {
        String(format: String(localized: "browserProfile.badgeHelp", defaultValue: "Browser profile: %@", table: "BrowserProfiles", bundle: .module), name)
    }
}
