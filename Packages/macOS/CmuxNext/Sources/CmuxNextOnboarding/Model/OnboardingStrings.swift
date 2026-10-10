import CmuxNextBrowserImport
import Foundation

/// User-facing onboarding text (Localizable.xcstrings in this module).
enum OnboardingStrings {
    static var importButton: String { String(localized: "onboarding.button.import", defaultValue: "Import", bundle: .module) }
    static var skip: String { String(localized: "onboarding.button.skip", defaultValue: "Skip", bundle: .module) }
    static var done: String { String(localized: "onboarding.button.done", defaultValue: "Done", bundle: .module) }

    // Import
    static var importTitle: String { String(localized: "onboarding.import.title2", defaultValue: "Import from Browsers", bundle: .module) }
    static var detecting: String { String(localized: "onboarding.import.detecting", defaultValue: "Looking for browsers…", bundle: .module) }
    static var findBrowsers: String { String(localized: "onboarding.import.findBrowsers", defaultValue: "Find Browsers", bundle: .module) }
    /// Where the browser list goes before Find Browsers ran (as short as "Looking for browsers…").
    static var notSearched: String { String(localized: "onboarding.import.notSearched", defaultValue: "Not looked for yet.", bundle: .module) }
    static var noBrowsers: String { String(localized: "onboarding.import.none", defaultValue: "No other browsers found on this Mac.", bundle: .module) }
    static var fullDiskAccessSubtitle: String { String(localized: "onboarding.import.fda.subtitle", defaultValue: "Needs Full Disk Access", bundle: .module) }
    static var openSystemSettings: String { String(localized: "onboarding.button.openSystemSettings", defaultValue: "Open System Settings", bundle: .module) }

    static var importWaiting: String { String(localized: "onboarding.import.waiting", defaultValue: "Waiting", bundle: .module) }
    static var importRowFailed: String { String(localized: "onboarding.import.rowFailed", defaultValue: "Couldn’t read", bundle: .module) }
    static var importedNothing: String {
        String(localized: "onboarding.import.importedNothing", defaultValue: "Done. These profiles had nothing new to bring.", bundle: .module)
    }
    static var importSomeFailed: String {
        String(localized: "onboarding.import.someFailed", defaultValue: "Some profiles couldn’t be read; hover one for why.", bundle: .module)
    }
    /// "Imported: Bookmarks 1,204 · History 8,311".
    static func imported(_ counts: String) -> String {
        String(format: String(localized: "onboarding.import.imported", defaultValue: "Imported: %@", bundle: .module), counts)
    }
    static var back: String { String(localized: "onboarding.button.back", defaultValue: "Back", bundle: .module) }
    static var importWithoutPasswords: String {
        String(localized: "onboarding.button.importWithoutPasswords", defaultValue: "Import Without Passwords", bundle: .module)
    }
    static var passwordsTitle: String {
        String(localized: "onboarding.passwords.title", defaultValue: "Bring saved passwords from these profiles?", bundle: .module)
    }
    /// `items`: the Keychain item names, each already in quotation marks.
    static func passwordsKeychain(_ items: String) -> String {
        String(format: String(localized: "onboarding.passwords.keychain2",
                              defaultValue: "Import asks you to confirm with Touch ID or your password. Then macOS asks whether cmux may use %@, the Keychain item the browser locks its saved passwords with. Choose Allow, and cmux unlocks them once, on this Mac.",
                              bundle: .module), items)
    }
    /// Only Firefox profiles chosen: no Keychain item to allow.
    static var passwordsFirefoxOnly: String {
        String(localized: "onboarding.passwords.firefoxOnly",
               defaultValue: "Import asks you to confirm with Touch ID or your password. Firefox keeps its key in the profile, so macOS asks for no Keychain item. If a Firefox profile has a primary password, cmux asks for it once and does not keep it.",
               bundle: .module)
    }
    /// Follows the Keychain paragraph when the choice mixes Chromium browsers and Firefox.
    static var passwordsFirefoxPrimary: String {
        String(localized: "onboarding.passwords.firefoxPrimary",
               defaultValue: "If a Firefox profile has a primary password, cmux asks for it once and does not keep it.", bundle: .module)
    }
    /// The consent screen's paragraph: Chromium browsers name the Keychain items macOS asks about
    /// (`quote` puts them in quotation marks); Firefox keeps its key in the profile.
    static func passwordsConsent(keychainItems: [String], includesFirefox: Bool, quote: ([String]) -> String) -> String {
        guard !keychainItems.isEmpty else { return passwordsFirefoxOnly }
        let keychain = passwordsKeychain(quote(keychainItems))
        return includesFirefox ? keychain + " " + passwordsFirefoxPrimary : keychain
    }
    /// macOS shows it as “cmux is trying to …” in the Touch ID sheet.
    static var passwordsAuthReason: String {
        String(localized: "onboarding.passwords.authReason", defaultValue: "import saved passwords from your other browsers", bundle: .module)
    }
    static var passwordsAuthDenied: String {
        String(localized: "onboarding.passwords.authDenied",
               defaultValue: "Nothing was read: the confirmation didn’t finish. Click Import to try again, or import without passwords.",
               bundle: .module)
    }
    static var passwordsStore: String {
        String(localized: "onboarding.passwords.store",
               defaultValue: "They go into cmux’s own encrypted password store, where autofill finds them. Agents never see them, and nothing is read until you click Import.",
               bundle: .module)
    }
    /// "Already saved with a different password: 2. cmux kept the saved password."
    static func passwordsConflicts(_ count: String) -> String {
        String(format: String(localized: "onboarding.import.passwordsConflicts",
                              defaultValue: "Already saved with a different password: %@. cmux kept the saved password.",
                              bundle: .module), count)
    }
    /// The finished line's password counts, counts only: skipped (other than conflicts), then
    /// differing passwords that were kept. Empty when there is neither.
    static func passwordsSummary(_ reports: [PasswordImportReport]) -> String {
        let skipped = reports.reduce(0) { $0 + $1.notImportedOtherThanConflicts }
        let conflicts = reports.reduce(0) { $0 + $1.conflicts }
        var parts: [String] = []
        if skipped > 0 { parts.append(passwordsSkipped(skipped.formatted(.number))) }
        if conflicts > 0 { parts.append(passwordsConflicts(conflicts.formatted(.number))) }
        return parts.joined(separator: " ")
    }
    /// "Passwords skipped: 9" (already saved, or not a web sign-in).
    static func passwordsSkipped(_ count: String) -> String {
        String(format: String(localized: "onboarding.import.passwordsSkipped", defaultValue: "Passwords skipped: %@", bundle: .module), count)
    }
    static var passwordsNotRead: String {
        String(localized: "onboarding.import.passwordsNotRead",
               defaultValue: "Some passwords weren’t imported: macOS didn’t allow the key, or the file couldn’t be read.", bundle: .module)
    }
    static func kind(_ kind: ImportDataKind) -> String {
        switch kind {
        case .bookmarks: String(localized: "onboarding.kind.bookmarks", defaultValue: "Bookmarks", bundle: .module)
        case .history: String(localized: "onboarding.kind.history", defaultValue: "History", bundle: .module)
        case .cookies: String(localized: "onboarding.kind.signIns", defaultValue: "Sign-ins", bundle: .module)
        case .openTabs: String(localized: "onboarding.kind.openTabs", defaultValue: "Open Tabs", bundle: .module)
        case .extensions: String(localized: "onboarding.kind.extensions", defaultValue: "Extensions", bundle: .module)
        case .passwords: String(localized: "onboarding.kind.passwords", defaultValue: "Passwords", bundle: .module)
        }
    }

    /// "Google Chrome · Work" (Safari and one-profile browsers: the browser name).
    static func profileName(_ profile: BrowserSourceProfile) -> String {
        profile.directoryName.isEmpty || profile.browser.family == .safari || profile.browser.family.isPrivateStore
            ? profile.browser.displayName : "\(profile.browser.displayName) · \(profile.displayName)"
    }
}
