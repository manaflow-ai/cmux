import Foundation

/// Localized text of browser profiles (Resources/BrowserProfiles.xcstrings).
public nonisolated enum BrowserProfileStrings {
    /// Name of the built-in profile until the user renames it.
    public static var defaultName: String {
        String(localized: "browserProfile.defaultName", defaultValue: "Default", table: "BrowserProfiles", bundle: .localizedModule)
    }

    /// The profile menu's line under the tab's profile: why the tab has it, the built-in default too (cmuxterm-hq
    /// RFD 0125, D2: "one line saying why this tab has it").
    public static func reason(_ source: BrowserProfileCascade.Source) -> String {
        switch source {
        case .workspace:
            String(localized: "browserProfile.reason.workspace", defaultValue: "This workspace's profile", table: "BrowserProfiles", bundle: .localizedModule)
        case .space:
            String(localized: "browserProfile.reason.space", defaultValue: "This space's profile", table: "BrowserProfiles", bundle: .localizedModule)
        case .tab:
            String(localized: "browserProfile.reason.tab", defaultValue: "Chosen for this tab", table: "BrowserProfiles", bundle: .localizedModule)
        case .builtIn:
            String(localized: "browserProfile.reason.builtIn", defaultValue: "Default for all workspaces", table: "BrowserProfiles", bundle: .localizedModule)
        }
    }

    /// The profile menu's line under an incognito tab's disc: when its data goes (as the window's own help says).
    public static var incognitoReason: String {
        String(localized: "browserProfile.reason.incognito", defaultValue: "Deleted when the last incognito window closes",
               table: "BrowserProfiles", bundle: .localizedModule)
    }
}
