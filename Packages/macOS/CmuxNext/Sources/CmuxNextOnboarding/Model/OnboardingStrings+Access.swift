import Foundation

/// The folder grant explainer, the Keychain explainer and the CSV fallback.
extension OnboardingStrings {
    static var continueTitle: String { String(localized: "onboarding.button.continue", defaultValue: "Continue", bundle: .module) }

    // Folder grant
    /// The row button of a browser cmux has no access to yet.
    static var allowAccess: String { String(localized: "onboarding.access.allow", defaultValue: "Allow Access…", bundle: .module) }
    static var accessNeeded: String { String(localized: "onboarding.access.needed", defaultValue: "No access yet", bundle: .module) }
    static func accessTitle(_ browser: String) -> String {
        String(format: String(localized: "onboarding.access.title", defaultValue: "Allow access to %@", bundle: .module), browser)
    }
    static var accessNone: String {
        String(localized: "onboarding.access.none",
               defaultValue: "cmux doesn’t have access to other browsers’ profiles on this Mac.", bundle: .module)
    }
    static func accessHow(_ browser: String) -> String {
        String(format: String(localized: "onboarding.access.how",
                              defaultValue: "To import from %@, give cmux access to its profile folder:", bundle: .module), browser)
    }
    static var accessStepContinue: String {
        String(localized: "onboarding.access.step1", defaultValue: "1. Select Continue.", bundle: .module)
    }
    /// Followed by the folder on its own line (~/Library/Application Support/Google/Chrome).
    static var accessStepOpen: String {
        String(localized: "onboarding.access.step2.open",
               defaultValue: "2. In the file picker, open this folder and choose Allow Access:", bundle: .module)
    }
    static func accessNotGranted(_ path: String) -> String {
        String(format: String(localized: "onboarding.access.notGranted",
                              defaultValue: "cmux didn’t get access. Choose %@ in the file picker.", bundle: .module), path)
    }

    /// The open panel's button.
    static var accessPanelPrompt: String { String(localized: "onboarding.access.panelPrompt", defaultValue: "Allow Access", bundle: .module) }
    static func accessPanelMessage(_ browser: String) -> String {
        String(format: String(localized: "onboarding.access.panelMessage",
                              defaultValue: "Select “Allow Access” to let cmux read your %@ data.", bundle: .module), browser)
    }

    // Keychain explainer (right before saved passwords are decrypted)
    static var beginImporting: String {
        String(localized: "onboarding.button.beginImporting", defaultValue: "Begin Importing", bundle: .module)
    }
    static var skipImporting: String {
        String(localized: "onboarding.button.skipImporting", defaultValue: "Skip Importing", bundle: .module)
    }
    static var unlockTitle: String {
        String(localized: "onboarding.unlock.title", defaultValue: "Unlock your data for import", bundle: .module)
    }
    /// `items`: the Keychain item names, each already in quotation marks.
    static func unlockLine(_ items: String) -> String {
        String(format: String(localized: "onboarding.unlock.line",
                              defaultValue: "Some data is encrypted, so macOS will ask for your computer password to let cmux use %@ and bring it in securely.",
                              bundle: .module), items)
    }

    // CSV fallback
    static var importPasswordsCSV: String {
        String(localized: "onboarding.import.passwordsCSV", defaultValue: "Import Passwords from CSV…", bundle: .module)
    }
}
