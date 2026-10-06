import CmuxNextBrowserImport
import Foundation

/// User-facing onboarding text (Localizable.xcstrings in this module).
enum OnboardingStrings {
    static var windowTitle: String { String(localized: "onboarding.window.title", defaultValue: "Welcome to cmux", bundle: .module) }
    static var continueButton: String { String(localized: "onboarding.button.continue", defaultValue: "Continue", bundle: .module) }
    static var importButton: String { String(localized: "onboarding.button.import", defaultValue: "Import", bundle: .module) }
    static var skip: String { String(localized: "onboarding.button.skip", defaultValue: "Skip", bundle: .module) }
    static var done: String { String(localized: "onboarding.button.done", defaultValue: "Done", bundle: .module) }
    static func stepCounter(_ index: Int, _ count: Int) -> String {
        String(format: String(localized: "onboarding.step.of", defaultValue: "%1$lld of %2$lld", bundle: .module), index, count)
    }

    static func stepCounter(_ index: Int, _ count: Int, step: OnboardingModel.Step) -> String {
        let counter = stepCounter(index, count)
        guard step == .importData else { return counter }
        return String(format: String(localized: "onboarding.step.importOf", defaultValue: "Import · %@", bundle: .module), counter)
    }

    // Role
    static var roleTitle: String { String(localized: "onboarding.role.title", defaultValue: "Which best describes your work?", bundle: .module) }
    static var roleSubtitle: String {
        String(localized: "onboarding.role.subtitle", defaultValue: "cmux shapes your first task around it.", bundle: .module)
    }
    static var roleDescribe: String { String(localized: "onboarding.role.describe", defaultValue: "Describe something else", bundle: .module) }
    static var roleSuggestTasks: String {
        String(localized: "onboarding.role.suggestTasks", defaultValue: "Suggest personalized tasks", bundle: .module)
    }
    static func roleName(_ role: OnboardingRole) -> String {
        switch role {
        case .engineering: String(localized: "onboarding.role.engineering", defaultValue: "Engineering", bundle: .module)
        case .dataScience: String(localized: "onboarding.role.dataScience", defaultValue: "Data science", bundle: .module)
        case .product: String(localized: "onboarding.role.product", defaultValue: "Product", bundle: .module)
        case .design: String(localized: "onboarding.role.design", defaultValue: "Design", bundle: .module)
        case .marketing: String(localized: "onboarding.role.marketing", defaultValue: "Marketing", bundle: .module)
        case .sales: String(localized: "onboarding.role.sales", defaultValue: "Sales", bundle: .module)
        case .finance: String(localized: "onboarding.role.finance", defaultValue: "Finance", bundle: .module)
        case .operations: String(localized: "onboarding.role.operations", defaultValue: "Operations", bundle: .module)
        case .peopleAndHR: String(localized: "onboarding.role.peopleAndHR", defaultValue: "People & HR", bundle: .module)
        case .legal: String(localized: "onboarding.role.legal", defaultValue: "Legal", bundle: .module)
        case .student: String(localized: "onboarding.role.student", defaultValue: "Student", bundle: .module)
        }
    }

    // Default browser
    static var browserTitle: String { String(localized: "onboarding.browser.title2", defaultValue: "Default Browser", bundle: .module) }
    static var browserSubtitle: String {
        String(localized: "onboarding.browser.subtitle2", defaultValue: "Open links from other apps in cmux.", bundle: .module)
    }
    static func currentBrowser(_ name: String) -> String {
        String(format: String(localized: "onboarding.browser.current", defaultValue: "Current default: %@", bundle: .module), name)
    }
    static var isDefaultBrowser: String { String(localized: "onboarding.browser.isDefault", defaultValue: "cmux is your default browser.", bundle: .module) }
    static var makeDefaultBrowser: String { String(localized: "onboarding.browser.make", defaultValue: "Make Default Browser", bundle: .module) }
    static var waiting: String { String(localized: "onboarding.browser.waiting", defaultValue: "Waiting for macOS…", bundle: .module) }
    static func systemRefused(_ reason: String) -> String {
        String(format: String(localized: "onboarding.system.refused", defaultValue: "macOS did not make the change: %@", bundle: .module), reason)
    }

    // Import
    static var importTitle: String { String(localized: "onboarding.import.title2", defaultValue: "Import from Browsers", bundle: .module) }
    static var importSubtitle: String {
        String(localized: "onboarding.import.subtitle3", defaultValue: "Each profile becomes a cmux profile. Nothing leaves this Mac.", bundle: .module)
    }
    static var detecting: String { String(localized: "onboarding.import.detecting", defaultValue: "Looking for browsers…", bundle: .module) }
    static var noBrowsers: String { String(localized: "onboarding.import.none", defaultValue: "No other browsers found on this Mac.", bundle: .module) }
    static func importing(_ profile: String) -> String {
        String(format: String(localized: "onboarding.import.progress", defaultValue: "Importing %@…", bundle: .module), profile)
    }
    static var keychainNote: String {
        String(localized: "onboarding.import.keychainNote", defaultValue: "macOS asks before cmux reads each browser's sign-ins.", bundle: .module)
    }
    static var fullDiskAccessTitle: String { String(localized: "onboarding.import.fda.title", defaultValue: "Safari needs Full Disk Access", bundle: .module) }
    static var fullDiskAccessSubtitle: String { String(localized: "onboarding.import.fda.subtitle", defaultValue: "Needs Full Disk Access", bundle: .module) }
    static var openSystemSettings: String { String(localized: "onboarding.button.openSystemSettings", defaultValue: "Open System Settings", bundle: .module) }
    static var checkAgain: String { String(localized: "onboarding.import.fda.recheck", defaultValue: "Check Again", bundle: .module) }

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
        profile.directoryName.isEmpty || profile.browser.family == .safari || profile.browser.family == .webkit
            ? profile.browser.displayName : "\(profile.browser.displayName) · \(profile.displayName)"
    }

    // Theme
    static var themeTitle: String { String(localized: "onboarding.theme.title", defaultValue: "Theme", bundle: .module) }
    static var themeSubtitle: String {
        String(localized: "onboarding.theme.subtitle", defaultValue: "A Ghostty theme for cmux. Your Ghostty config does not change.", bundle: .module)
    }
    static var ghosttyTheme: String { String(localized: "onboarding.welcome.ghosttyTheme", defaultValue: "Your Ghostty Theme", bundle: .module) }
    static var appleSystemTheme: String {
        String(localized: "onboarding.theme.appleSystem", defaultValue: "Apple System (follows appearance)", bundle: .module)
    }
    /// The name a theme choice shows.
    static func themeName(_ choice: ThemeChoice) -> String { choice.label ?? choice.name ?? ghosttyTheme }
    static var previewLabel: String { String(localized: "onboarding.preview.label", defaultValue: "Preview of cmux with your choices", bundle: .module) }

    // Accounts
    static var accountsTitle: String { String(localized: "onboarding.accounts.title2", defaultValue: "Accounts", bundle: .module) }
    static var accountsSubtitle: String {
        String(localized: "onboarding.accounts.subtitle2", defaultValue: "Sign-ins cmux found on this Mac. Nothing is uploaded unless you choose Connect.", bundle: .module)
    }
}
