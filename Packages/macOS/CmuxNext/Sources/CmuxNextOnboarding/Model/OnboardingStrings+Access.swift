import Foundation

/// The folder grant explainer, the Keychain explainer and the CSV fallback.
extension OnboardingStrings {
    static var continueTitle: String { String(localized: "onboarding.button.continue", defaultValue: "Continue", bundle: .localizedModule) }

    static func accessTitle(_ browser: String) -> String {
        String(format: String(localized: "onboarding.access.title", defaultValue: "Allow access to %@", bundle: .localizedModule), browser)
    }
    static func accessNotGranted(_ path: String) -> String {
        String(format: String(localized: "onboarding.access.notGranted",
                              defaultValue: "cmux didn’t get access. Choose %@ in the file picker.", bundle: .localizedModule), path)
    }

    /// The open panel's button.
    static var accessPanelPrompt: String { String(localized: "onboarding.access.panelPrompt", defaultValue: "Allow Access", bundle: .localizedModule) }
    static func accessPanelMessage(_ browser: String) -> String {
        String(format: String(localized: "onboarding.access.panelMessage",
                              defaultValue: "Select “Allow Access” to let cmux read your %@ data.", bundle: .localizedModule), browser)
    }

    // Keychain explainer (right before saved passwords are decrypted)
    static var beginImporting: String {
        String(localized: "onboarding.button.beginImporting", defaultValue: "Begin Importing", bundle: .localizedModule)
    }
    static var skipImporting: String {
        String(localized: "onboarding.button.skipImporting", defaultValue: "Skip Importing", bundle: .localizedModule)
    }
}
