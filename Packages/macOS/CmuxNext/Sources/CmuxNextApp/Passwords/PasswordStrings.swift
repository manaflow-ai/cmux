import Foundation

/// The Swift side's strings of the Passwords page (table `Passwords`; the page's own
/// `passwords.page.` keys live in the same table, see webviews/scripts/pages/gen-strings.mjs).
nonisolated enum PasswordStrings {
    static var pageTitle: String { String(localized: "passwords.page.title", defaultValue: "Passwords", table: "Passwords", bundle: .module) }
    static var availableAfterUpdate: String {
        String(localized: "passwords.page.availableAfterUpdate", defaultValue: "Available after the next update", table: "Passwords", bundle: .module)
    }
    static var userOnly: String {
        String(localized: "passwords.error.userOnly", defaultValue: "Only you can do this, with a click or a key in the Passwords page.",
               table: "Passwords", bundle: .module)
    }
    static var notFound: String {
        String(localized: "passwords.error.notFound", defaultValue: "This item is no longer saved.", table: "Passwords", bundle: .module)
    }
    static var authFailed: String {
        String(localized: "passwords.error.authFailed", defaultValue: "cmux could not confirm that it is you.", table: "Passwords", bundle: .module)
    }
    static var copyPassword: String {
        String(localized: "passwords.reveal.copy", defaultValue: "Copy Password", table: "Passwords", bundle: .module)
    }
    static var done: String { String(localized: "passwords.reveal.done", defaultValue: "Done", table: "Passwords", bundle: .module) }
    static func exportFileName(_ profile: String) -> String {
        String(format: String(localized: "passwords.export.fileName", defaultValue: "cmux Passwords (%@).csv", table: "Passwords", bundle: .module), profile)
    }
    static func passwordCount(_ count: Int) -> String {
        String(format: String(localized: "passwords.delete.count", defaultValue: "%lld saved passwords", table: "Passwords", bundle: .module), count)
    }
    static var deletePasswordDetail: String {
        String(localized: "passwords.delete.passwordDetail", defaultValue: "cmux can no longer fill this password. You cannot undo this.",
               table: "Passwords", bundle: .module)
    }
    static var deletePasskeyDetail: String {
        String(localized: "passwords.delete.passkeyDetail", defaultValue: "You can no longer sign in to %@ with this passkey. You cannot undo this.",
               table: "Passwords", bundle: .module)
    }
    static var deleteExceptionDetail: String {
        String(localized: "passwords.delete.exceptionDetail", defaultValue: "cmux can offer to save passwords on this site again.",
               table: "Passwords", bundle: .module)
    }
    static var revealReason: String {
        String(localized: "passwords.auth.reveal", defaultValue: "show the saved password for %@", table: "Passwords", bundle: .module)
    }
    static var copyReason: String {
        String(localized: "passwords.auth.copy", defaultValue: "copy the saved password for %@", table: "Passwords", bundle: .module)
    }
    static var exportReason: String {
        String(localized: "passwords.auth.export", defaultValue: "export your saved passwords", table: "Passwords", bundle: .module)
    }
    static var exportTitle: String {
        String(localized: "passwords.export.title", defaultValue: "Export the saved passwords of “%@”?", table: "Passwords", bundle: .module)
    }
    static var exportDetail: String {
        String(localized: "passwords.export.detail",
               defaultValue: "The file contains every saved password as plain text. Anyone who can read the file can read the passwords.",
               table: "Passwords", bundle: .module)
    }

    // MARK: Browser profile delete (the sheet names what goes with the profile)

    static func deleteProfileTitle(_ name: String) -> String {
        String(format: String(localized: "passwords.profileDelete.title", defaultValue: "Delete browser profile “%@”?", table: "Passwords", bundle: .module), name)
    }
    static var deleteProfileBody: String {
        String(localized: "passwords.profileDelete.body", defaultValue: "Its history, cookies and site data are deleted.", table: "Passwords", bundle: .module)
    }
    static func deleteProfilePasswords(_ count: Int) -> String {
        String(format: String(localized: "passwords.profileDelete.passwords", defaultValue: "Saved passwords deleted with it: %lld.",
                              table: "Passwords", bundle: .module), count)
    }
    static func deleteProfilePasskeys(_ count: Int) -> String {
        String(format: String(localized: "passwords.profileDelete.passkeys", defaultValue: "Passkeys that stop working with it: %lld.",
                              table: "Passwords", bundle: .module), count)
    }
    static var deleteProfilePasswordsUnknown: String {
        String(localized: "passwords.profileDelete.passwordsUnknown", defaultValue: "Its saved passwords are deleted with it.",
               table: "Passwords", bundle: .module)
    }
    static var deleteProfilePasskeysUnknown: String {
        String(localized: "passwords.profileDelete.passkeysUnknown", defaultValue: "Its passkeys stop working.", table: "Passwords", bundle: .module)
    }
    static var profileDeleteHoldsSecrets: String {
        String(localized: "passwords.profileDelete.refusedSecrets",
               defaultValue: "This browser profile holds saved passwords or passkeys. Only you can delete it, in the cmux app.",
               table: "Passwords", bundle: .module)
    }
    static var profileDeleteMayHoldSecrets: String {
        String(localized: "passwords.profileDelete.refusedUnknown",
               defaultValue: "This browser profile may hold saved passwords. Only you can delete it, in the cmux app.",
               table: "Passwords", bundle: .module)
    }
    static var exportOff: String {
        String(localized: "passwords.error.exportOff",
               defaultValue: "Password export is off. Turn on “Allow Password Export” in Settings > Browser.",
               table: "Passwords", bundle: .module)
    }
    static var deleteProfileButton: String {
        String(localized: "passwords.profileDelete.delete", defaultValue: "Delete", table: "Passwords", bundle: .module)
    }
}
