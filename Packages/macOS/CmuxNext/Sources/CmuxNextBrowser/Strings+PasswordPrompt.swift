import Foundation

// Chromium's password save and update prompts, asked in the prompt bar (CEFPasswordPrompts).
extension Strings {
    static func passwordSavePrompt(_ origin: String) -> String {
        String(localized: "browser.password.savePrompt", defaultValue: "Save password for \(origin)?", bundle: .module)
    }
    static func passwordUpdatePrompt(_ origin: String) -> String {
        String(localized: "browser.password.updatePrompt", defaultValue: "Update the saved password for \(origin)?", bundle: .module)
    }
    static var passwordSave: String { String(localized: "browser.password.save", defaultValue: "Save", bundle: .module) }
    static var passwordUpdate: String { String(localized: "browser.password.update", defaultValue: "Update", bundle: .module) }
    static var passwordNever: String { String(localized: "browser.password.never", defaultValue: "Never for This Site", bundle: .module) }
    static var passwordNotNow: String { String(localized: "browser.password.notNow", defaultValue: "Not Now", bundle: .module) }
}
