import Foundation

/// The folder grant explainer, the Keychain explainer and the CSV fallback.
extension OnboardingStrings {
    static var continueTitle: String { String(localized: "onboarding.button.continue", defaultValue: "Continue", bundle: .l10n) }

    // Folder grant
    /// The row button of a browser cmux has no access to yet.
    static var allowAccess: String { String(localized: "onboarding.access.allow", defaultValue: "Allow Access…", bundle: .l10n) }
    static var accessNeeded: String { String(localized: "onboarding.access.needed", defaultValue: "No access yet", bundle: .l10n) }
    static func accessTitle(_ browser: String) -> String {
        String(format: String(localized: "onboarding.access.title", defaultValue: "Allow access to %@", bundle: .l10n), browser)
    }
    static var accessNone: String {
        String(localized: "onboarding.access.none",
               defaultValue: "cmux doesn’t have access to other browsers’ profiles on this Mac.", bundle: .l10n)
    }
    static func accessHow(_ browser: String) -> String {
        String(format: String(localized: "onboarding.access.how",
                              defaultValue: "To import from %@, give cmux access to its profile folder:", bundle: .l10n), browser)
    }
    static var accessStepContinue: String {
        String(localized: "onboarding.access.step1", defaultValue: "1. Select Continue.", bundle: .l10n)
    }
    /// Followed by the folder on its own line (~/Library/Application Support/Google/Chrome).
    static var accessStepOpen: String {
        String(localized: "onboarding.access.step2.open",
               defaultValue: "2. In the file picker, open this folder and choose Allow Access:", bundle: .l10n)
    }
    static func accessNotGranted(_ path: String) -> String {
        String(format: String(localized: "onboarding.access.notGranted",
                              defaultValue: "cmux didn’t get access. Choose %@ in the file picker.", bundle: .l10n), path)
    }

    /// The open panel's button.
    static var accessPanelPrompt: String { String(localized: "onboarding.access.panelPrompt", defaultValue: "Allow Access", bundle: .l10n) }
    static func accessPanelMessage(_ browser: String) -> String {
        String(format: String(localized: "onboarding.access.panelMessage",
                              defaultValue: "Select “Allow Access” to let cmux read your %@ data.", bundle: .l10n), browser)
    }

    // Keychain explainer (right before saved passwords are decrypted)
    static var beginImporting: String {
        String(localized: "onboarding.button.beginImporting", defaultValue: "Begin Importing", bundle: .l10n)
    }
    static var skipImporting: String {
        String(localized: "onboarding.button.skipImporting", defaultValue: "Skip Importing", bundle: .l10n)
    }
    static var unlockTitle: String {
        String(localized: "onboarding.unlock.title", defaultValue: "Unlock your data for import", bundle: .l10n)
    }
    /// `items`: the Keychain item names, each already in quotation marks.
    static func unlockLine(_ items: String) -> String {
        String(format: String(localized: "onboarding.unlock.line",
                              defaultValue: "Some data is encrypted, so macOS will ask for your computer password to let cmux use %@ and bring it in securely.",
                              bundle: .l10n), items)
    }

    // CSV fallback
    static var importPasswordsCSV: String {
        String(localized: "onboarding.import.passwordsCSV", defaultValue: "Import Passwords from CSV…", bundle: .l10n)
    }
}
