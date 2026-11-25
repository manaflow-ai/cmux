import Foundation

// Chromium's password save and update prompts, asked in the prompt bar (CEFPasswordPrompts).
extension Strings {
    static func passwordSavePrompt(_ origin: String) -> String {
        String(localized: "browser.password.savePrompt", defaultValue: "Save password for \(origin)?", bundle: .localizedModule)
    }
    static func passwordUpdatePrompt(_ origin: String) -> String {
        String(localized: "browser.password.updatePrompt", defaultValue: "Update the saved password for \(origin)?", bundle: .localizedModule)
    }
    static var passwordSave: String { String(localized: "browser.password.save", defaultValue: "Save", bundle: .localizedModule) }
    static var passwordUpdate: String { String(localized: "browser.password.update", defaultValue: "Update", bundle: .localizedModule) }
    static var passwordNever: String { String(localized: "browser.password.never", defaultValue: "Never for This Site", bundle: .localizedModule) }
    static var passwordNotNow: String { String(localized: "browser.password.notNow", defaultValue: "Not Now", bundle: .localizedModule) }
}
