import CmuxNextBrowser
import Foundation

/// Strings of the browser profile handlers and prompts
/// (Resources/BrowserProfiles.xcstrings).
nonisolated enum BrowserProfileAppStrings {
    static func defaultName(_ number: Int) -> String {
        String(format: text("browserProfiles.defaultName", "Profile %lld"), locale: Locale.current, number)
    }
    static var renameTitle: String { text("browserProfiles.renameTitle", "Rename Browser Profile") }
    static var iconTitle: String { text("browserProfiles.iconTitle", "Browser Profile Icon (SF Symbol name or one emoji)") }
    static func deleteTitle(_ name: String) -> String {
        String(format: text("browserProfiles.deleteTitle", "Delete browser profile “%@” and its data?"), name)
    }
    static func deleteBody(_ fallback: String) -> String {
        String(format: text("browserProfiles.deleteBody",
                            "Its cookies, logins, history, extensions and site permissions are deleted. Its open tabs reopen in “%@”."), fallback)
    }
    static var delete: String { text("browserProfiles.delete", "Delete") }
    static func movedNotice(to target: String, from source: String) -> String {
        String(format: text("browserProfiles.movedNotice", "Opened in “%1$@”. Cookies, logins and page state stayed in “%2$@”."), target, source)
    }
    static func duplicatedNotice(_ target: String) -> String {
        String(format: text("browserProfiles.duplicatedNotice", "Opened a copy in “%@”. Cookies, logins and page state did not come along."), target)
    }
    static func noProfile(_ id: String) -> String { String(format: text("browserProfiles.refusal.noProfile", "no browser profile %@"), id) }
    static var profileRequired: String { text("browserProfiles.refusal.profileRequired", "a browserProfile argument is required") }
    static var defaultCannotBeDeleted: String {
        text("browserProfiles.refusal.defaultCannotBeDeleted", "the default browser profile cannot be deleted")
    }
    static var notBrowserTab: String { text("browserProfiles.refusal.notBrowserTab", "only a browser tab has a browser profile") }
    static var incognitoTab: String {
        text("browserProfiles.refusal.incognito", "an incognito tab keeps its incognito window's profile")
    }
    static var alreadyInProfile: String { text("browserProfiles.refusal.alreadyInProfile", "the tab already uses that browser profile") }
    static var invalidName: String { text("browserProfiles.refusal.invalidName", "the name must have 1 to 64 characters") }
    static var invalidIcon: String { text("browserProfiles.refusal.invalidIcon", "the icon must be an SF Symbol name or one emoji") }
    static var urlRequired: String { text("browserProfiles.refusal.urlRequired", "a url argument is required") }

    /// The typed reason of a refused edit.
    static func message(_ error: BrowserProfileBookError) -> String {
        switch error {
        case .unknownProfile: noProfile("")
        case .defaultProfile: defaultCannotBeDeleted
        case .invalidName: invalidName
        case .invalidID: noProfile("")
        case .invalidColor: RefusalStrings.colorMustBeOneOf("grey, blue, red, yellow, green, pink, purple, cyan, orange")
        case .invalidIcon: invalidIcon
        }
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "BrowserProfiles", bundle: .module)
    }
}
