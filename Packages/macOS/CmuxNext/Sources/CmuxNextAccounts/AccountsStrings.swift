import CmuxNextCodeRouter
import Foundation

/// Localized text of the Accounts screen (Localizable.xcstrings in this module).
enum AccountsStrings {
    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .localizedModule)
    }

    static func group(_ group: AIProvider.Group) -> String {
        switch group {
        case .chatGPT: text("accounts.group.chatgpt", "ChatGPT and Codex")
        case .anthropic: text("accounts.group.anthropic", "Anthropic")
        case .other: text("accounts.group.other", "Other Providers")
        case .local: text("accounts.group.local", "Local Models")
        }
    }

    static var signInToCmux: String { text("accounts.action.signInCmux", "Sign In to cmux") }
    static var refresh: String { text("accounts.action.refresh", "Refresh") }

    static var teamTitle: String { text("accounts.team.title", "Active Team") }
    static var teamHelp: String {
        text("accounts.team.help", "Cloud machines and phone access use this team.")
    }
    static var teamManaged: String { text("accounts.team.managed", "Your organization chose this device's team.") }
    static var teamSwitchFailed: String { text("accounts.team.switchFailed", "Could not switch teams. Try again.") }

    static func status(_ row: AccountRowState) -> String {
        guard let status = row.status, row.phase != .detecting else { return text("accounts.status.detecting", "Checking…") }
        if row.provider.isLocalServer {
            return status == .signedIn ? text("accounts.status.running", "Running") : text("accounts.status.notRunning", "Not running")
        }
        switch status {
        case .signedIn:
            return row.provider.acceptsPastedKey ? text("accounts.status.keyFound", "Key found") : text("accounts.status.signedIn", "Signed in")
        case .expired: return text("accounts.status.expired", "Expired")
        case .missing: return text("accounts.status.missing", "Not found")
        case .unknown: return text("accounts.status.unknown", "Unknown")
        }
    }

    static func source(_ label: String) -> String {
        String(format: text("accounts.source", "From %@"), label)
    }

    static func note(_ note: DetectionNote) -> String {
        switch note {
        case .savedAPIKey: text("accounts.detail.savedAPIKey", "API key")
        }
    }

    /// Get Key for a key page, Sign In when nothing was found, else Re-authenticate.
    static func reauthTitle(_ row: AccountRowState) -> String {
        if case .page = row.provider.reauthPlan { return getKey }
        return row.status == .missing ? signIn : reauthenticate
    }
    static var reauthenticate: String { text("accounts.action.reauth", "Re-authenticate") }
    static var signIn: String { text("accounts.action.signIn", "Sign In") }
    static var getKey: String { text("accounts.action.getKey", "Get Key") }
    static var signOut: String { text("accounts.action.signOut", "Sign Out") }
    /// No variable name: recovery copy names no environment variables (review-bot rules).
    static var shellSignInWins: String {
        text("accounts.hint.shellSignIn", "Your shell provides this sign-in, and it wins over a sign-in made here. Remove it from your shell setup for Re-authenticate or Sign Out to take effect.")
    }
    static var addKey: String { text("accounts.action.addKey", "Add Key…") }
    static var deleteSavedKey: String { text("accounts.action.deleteSavedKey", "Delete Saved Key") }

    // Paste sheet
    static func pasteKeyTitle(_ provider: String) -> String {
        String(format: text("accounts.paste.title", "Add %@ Key"), provider)
    }
    static var pasteKeyBody: String {
        text("accounts.paste.keychainBody", "The key goes to the macOS Keychain. cmux never writes it to cmux.json.")
    }
    static var pastePlaceholder: String { text("accounts.paste.placeholder", "Paste here") }
    static var saveToKeychain: String { text("accounts.paste.saveKeychain", "Save to Keychain") }
    static var cancel: String { text("accounts.paste.cancel", "Cancel") }

    // Errors
    static var errorBusy: String {
        text("accounts.error.busy", "Another action on this account is still running. Try again when it finishes.")
    }
    static var errorNoLocalPane: String {
        text("accounts.error.noLocalPane", "Open a workspace on this Mac first, then try again.")
    }
    static var errorNeedsPaste: String { text("accounts.error.needsPaste", "Paste a key or token first.") }
    static var errorInvalidFormat: String { text("accounts.error.invalidFormat", "That is not a valid key or token for this provider.") }
    static func errorFailed(_ detail: String) -> String {
        String(format: text("accounts.error.failed", "Failed: %@"), detail)
    }

    /// User-facing text for a Keychain save failure. Never includes a secret.
    static func message(for error: any Error) -> String {
        errorFailed(String(describing: error))
    }
}
