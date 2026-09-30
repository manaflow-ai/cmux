import CmuxNextBrowserImport
import Foundation

/// User-facing onboarding text (Localizable.xcstrings in this module).
enum OnboardingStrings {
    static var windowTitle: String { String(localized: "onboarding.window.title", defaultValue: "Welcome to cmux", bundle: .module) }
    static var continueButton: String { String(localized: "onboarding.button.continue", defaultValue: "Continue", bundle: .module) }
    static var back: String { String(localized: "onboarding.button.back", defaultValue: "Back", bundle: .module) }
    static var skip: String { String(localized: "onboarding.button.skip", defaultValue: "Skip", bundle: .module) }
    static var finish: String { String(localized: "onboarding.button.finish", defaultValue: "Start Using cmux", bundle: .module) }
    static func stepCounter(_ index: Int, _ count: Int) -> String {
        String(format: String(localized: "onboarding.step.counter", defaultValue: "Step %1$lld of %2$lld", bundle: .module), index, count)
    }

    // Welcome
    static var welcomeTitle: String { String(localized: "onboarding.welcome.title", defaultValue: "Welcome to cmux", bundle: .module) }
    static var welcomeSubtitle: String {
        String(localized: "onboarding.welcome.subtitle", defaultValue: "A terminal and browser for agents, built on Ghostty. Pick a look; you can change it any time.", bundle: .module)
    }
    static var theme: String { String(localized: "onboarding.welcome.theme", defaultValue: "Theme", bundle: .module) }
    static var ghosttyTheme: String { String(localized: "onboarding.welcome.ghosttyTheme", defaultValue: "Your Ghostty Theme", bundle: .module) }
    static var density: String { String(localized: "onboarding.welcome.density", defaultValue: "Density", bundle: .module) }
    static var compact: String { String(localized: "onboarding.density.compact", defaultValue: "Compact", bundle: .module) }
    static var comfortable: String { String(localized: "onboarding.density.comfortable", defaultValue: "Comfortable", bundle: .module) }
    static var themeNote: String {
        String(localized: "onboarding.welcome.themeNote", defaultValue: "cmux saves your pick in cmux.json. Your Ghostty config does not change.", bundle: .module)
    }

    // Import
    static var importTitle: String { String(localized: "onboarding.import.title", defaultValue: "Bring Your Browser", bundle: .module) }
    static var importSubtitle: String {
        String(localized: "onboarding.import.subtitle", defaultValue: "Import bookmarks, history, open tabs and extensions. Nothing leaves this Mac.", bundle: .module)
    }
    static var detecting: String { String(localized: "onboarding.import.detecting", defaultValue: "Looking for browsers…", bundle: .module) }
    static var noBrowsers: String { String(localized: "onboarding.import.none", defaultValue: "No other browsers found on this Mac.", bundle: .module) }
    static var nothingToImport: String { String(localized: "onboarding.import.profile.nothing", defaultValue: "Nothing to import", bundle: .module) }
    static var importButton: String { String(localized: "onboarding.import.start", defaultValue: "Import", bundle: .module) }
    static var importAgain: String { String(localized: "onboarding.import.again", defaultValue: "Import Again", bundle: .module) }
    static var cancel: String { String(localized: "onboarding.import.cancel", defaultValue: "Cancel", bundle: .module) }
    static func importing(_ profile: String) -> String {
        String(format: String(localized: "onboarding.import.progress", defaultValue: "Importing %@…", bundle: .module), profile)
    }
    static var saving: String { String(localized: "onboarding.import.saving", defaultValue: "Saving…", bundle: .module) }
    static var cancelled: String { String(localized: "onboarding.import.cancelled", defaultValue: "Import stopped. Profiles already imported are kept.", bundle: .module) }
    static func failed(_ reason: String) -> String {
        String(format: String(localized: "onboarding.import.failed", defaultValue: "Import failed: %@", bundle: .module), reason)
    }
    static func couldNotRead(_ profile: String) -> String {
        String(format: String(localized: "onboarding.import.couldNotRead", defaultValue: "Could not read %@.", bundle: .module), profile)
    }
    static var secretsNote: String {
        String(localized: "onboarding.import.secretsNote", defaultValue: "Passwords and cookies are not imported yet: they need Chromium's own importer, which cmux does not include yet.", bundle: .module)
    }
    static var profilesNote: String {
        String(localized: "onboarding.import.profilesNote", defaultValue: "Everything goes to your default browser profile, labeled by source, so it can move to its own profile later.", bundle: .module)
    }
    static var fullDiskAccessTitle: String { String(localized: "onboarding.import.fda.title", defaultValue: "Safari needs Full Disk Access", bundle: .module) }
    static var fullDiskAccessDetail: String {
        String(localized: "onboarding.import.fda.detail", defaultValue: "macOS protects Safari's bookmarks and history. Turn on cmux in Full Disk Access, then check again.", bundle: .module)
    }
    static var openSystemSettings: String { String(localized: "onboarding.button.openSystemSettings", defaultValue: "Open System Settings", bundle: .module) }
    static var checkAgain: String { String(localized: "onboarding.import.fda.recheck", defaultValue: "Check Again", bundle: .module) }
    static var openTabsNow: String { String(localized: "onboarding.import.tabs.open", defaultValue: "Open Tabs Now", bundle: .module) }
    static var tabsOpened: String { String(localized: "onboarding.import.tabs.opened", defaultValue: "Tabs Opened", bundle: .module) }
    static var extensionsTitle: String { String(localized: "onboarding.import.extensions.title", defaultValue: "Reinstall Extensions", bundle: .module) }
    static var extensionsDetail: String {
        String(localized: "onboarding.import.extensions.detail", defaultValue: "Extensions install from the Chrome Web Store. Open each one and click Add to Chrome.", bundle: .module)
    }
    static var install: String { String(localized: "onboarding.import.extensions.install", defaultValue: "Install", bundle: .module) }
    static var opened: String { String(localized: "onboarding.import.extensions.opened", defaultValue: "Opened", bundle: .module) }

    static func kind(_ kind: ImportDataKind) -> String {
        switch kind {
        case .bookmarks: String(localized: "onboarding.kind.bookmarks", defaultValue: "Bookmarks", bundle: .module)
        case .history: String(localized: "onboarding.kind.history", defaultValue: "History", bundle: .module)
        case .openTabs: String(localized: "onboarding.kind.openTabs", defaultValue: "Open Tabs", bundle: .module)
        case .extensions: String(localized: "onboarding.kind.extensions", defaultValue: "Extensions", bundle: .module)
        case .passwords: String(localized: "onboarding.kind.passwords", defaultValue: "Passwords", bundle: .module)
        case .cookies: String(localized: "onboarding.kind.cookies", defaultValue: "Cookies", bundle: .module)
        }
    }
}
