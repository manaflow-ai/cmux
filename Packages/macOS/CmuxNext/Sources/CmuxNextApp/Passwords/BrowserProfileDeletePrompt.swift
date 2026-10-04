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

/// Coordinator decision (2026-10-04): deleting a browser profile that holds saved passwords or
/// passkeys is person-only. A person (palette, menu, keyboard, the Settings page) gets the sheet
/// above; the CLI, MCP, scripts and other clients get a refusal that names the reason. A count
/// the build cannot read counts as "may hold", so automation is refused then too.
enum BrowserProfileSecretsGuard {
    static func isPerson(_ origin: ActionOrigin) -> Bool {
        true
    }

    /// Why automation may not delete a profile with these counts, nil when it may.
    static func refusal(_ counts: PasswordCounts) -> String? {
        nil
    }

    /// Counts the profile's secrets, then deletes it or answers the refusal.
    static func deleteIfNoSecrets(_ id: String, context: AppActionContext) -> ActionWork {
        Task { @MainActor in
            let service = context.services.pages.provider(.passwords) as? PasswordsPageService
            let counts = await service?.store.counts(profile: id) ?? PasswordCounts(passwords: nil, passkeys: nil)
            if let reason = refusal(counts) { return ActionWorkFailure(reason) }
            do {
                try context.services.browserProfiles.delete(id)
                return nil
            } catch {
                return ActionWorkFailure(String(describing: error))
            }
        }
    }
}
