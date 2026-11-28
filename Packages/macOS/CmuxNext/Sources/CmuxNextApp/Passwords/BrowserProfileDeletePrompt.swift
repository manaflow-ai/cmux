import CmuxNextActions
import Foundation

/// The sheet before a browser profile is deleted: it names how many saved passwords and
/// passkeys go with the profile (the coordinator's profile delete rule). A count the running
/// build cannot read is named without a number.
enum BrowserProfileDeletePrompt {
    static func prompt(_ invocation: ActionInvocation, _ context: AppActionContext) async -> DestructiveConfirmation.Prompt? {
        guard let record = try? context.browserProfile(invocation), !record.isDefault else { return nil }
        let service = context.services.pages.provider(.passwords) as? PasswordsPageService
        let counts = await service?.store.counts(profile: record.id) ?? PasswordCounts(passwords: nil, passkeys: nil)
        return DestructiveConfirmation.Prompt(title: PasswordStrings.deleteProfileTitle(context.services.browserProfiles.displayName(record.id)),
                                              body: body(counts), button: PasswordStrings.deleteProfileButton)
    }

    /// The sheet's text: the data that goes, then the passwords and passkeys.
    static func body(_ counts: PasswordCounts) -> String {
        [
            PasswordStrings.deleteProfileBody,
            counts.passwords.map(PasswordStrings.deleteProfilePasswords) ?? PasswordStrings.deleteProfilePasswordsUnknown,
            counts.passkeys.map(PasswordStrings.deleteProfilePasskeys) ?? PasswordStrings.deleteProfilePasskeysUnknown,
        ].joined(separator: " ")
    }
}
