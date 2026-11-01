import CmuxNextCodeRouter
import Foundation

/// Localized text of the Accounts screen (Localizable.xcstrings in this module).
enum AccountsStrings {
    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
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
        text("accounts.team.help", "Cloud machines, CodeRouter and phone access use this team.")
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
    static var connect: String { text("accounts.action.connect", "Connect to CodeRouter") }
    static var remove: String { text("accounts.action.remove", "Remove from CodeRouter") }
    static var unsupported: String { text("accounts.linked.unsupported", "CodeRouter does not route this provider yet.") }
    static var bedrockNeedsKeys: String {
        String(format: text("accounts.hint.bedrockKeys", "To connect, set %@ in your shell."), "AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY")
    }
    static var codexRefreshNote: String {
        text("accounts.confirm.codexNote", "CodeRouter stores this Codex sign-in, with its refresh token, and refreshes it on the server. The codex command on this Mac may then need codex login again.")
    }
    static var confirmConnect: String { text("accounts.confirm.connect", "Connect") }
    /// The onboarding list's one-word Connect (to CodeRouter).
    static var connected: String { text("accounts.outcome.connected", "Connected to CodeRouter") }
    static var removed: String { text("accounts.outcome.removed", "Removed from CodeRouter") }

    // Paste sheet
    static func pasteKeyTitle(_ provider: String) -> String {
        String(format: text("accounts.paste.title", "Add %@ Key"), provider)
    }
    static var pasteClaudeTitle: String { text("accounts.paste.claudeTitle", "Connect Claude Code") }
    static var pasteClaudeBody: String {
        text("accounts.paste.claudeBody", "CodeRouter needs a long-lived token. Run claude setup-token, then paste the token here. It goes to CodeRouter only.")
    }
    static var pasteKeyBody: String {
        text("accounts.paste.keyBody", "The key goes to the macOS Keychain or to CodeRouter. cmux never writes it to cmux.json.")
    }
    static var pastePlaceholder: String { text("accounts.paste.placeholder", "Paste here") }
    static var runSetupToken: String { text("accounts.paste.runSetupToken", "Run claude setup-token") }
    static var saveToKeychain: String { text("accounts.paste.saveKeychain", "Save to Keychain") }
    static var sendToCodeRouter: String { text("accounts.paste.sendCodeRouter", "Send to CodeRouter") }
    static var cancel: String { text("accounts.paste.cancel", "Cancel") }

    // Errors
    static var errorNotSignedIn: String { text("accounts.error.notSignedIn", "Sign in to cmux first.") }
    static var errorTimedOut: String { text("accounts.error.timedOut", "CodeRouter did not answer in time. Try again.") }
    static var errorBusy: String {
        text("accounts.error.busy", "Another action on this account is still running. Try again when it finishes.")
    }
    static var errorStaleList: String {
        text("accounts.error.staleList", "The account list changed. Refresh, then try again.")
    }
    static func errorProviderSignInFirst(_ provider: String) -> String {
        String(format: text("accounts.error.providerSignInFirst", "Sign in to %@ first, then try again."), provider)
    }
    static var errorNoLocalPane: String {
        text("accounts.error.noLocalPane", "Open a workspace on this Mac first, then try again.")
    }
    static var errorNeedsPaste: String { text("accounts.error.needsPaste", "Paste a key or token first.") }
    static var errorInvalidFormat: String { text("accounts.error.invalidFormat", "That is not a valid key or token for this provider.") }
    static var errorIncomplete: String { text("accounts.error.incomplete", "This sign-in is incomplete. Re-authenticate, then try again.") }
    static func errorMissingEnvironment(_ names: String) -> String {
        String(format: text("accounts.error.missingEnv", "Set %@ in your shell, then try again."), names)
    }
    static func errorFailed(_ detail: String) -> String {
        String(format: text("accounts.error.failed", "Failed: %@"), detail)
    }

    /// Why Connect cannot run for `row`, naming what to fix, or nil when it can.
    static func connectRefusal(_ row: AccountRowState) -> String? {
        guard row.isLinkable else { return unsupported }
        guard row.cmuxSignedIn else { return errorNotSignedIn }
        if let problem = row.codeRouterProblem { return problem }
        guard !row.canConnect else { return nil }
        if row.provider.codeRouterLink == .bedrockKeys {
            return errorMissingEnvironment(AccountRowState.bedrockKeyNames.joined(separator: ", "))
        }
        return errorProviderSignInFirst(row.provider.displayName)
    }

    /// User-facing text for an operation failure. Never includes a secret:
    /// CodeRouter messages come from the server's message field.
    static func message(for error: any Error) -> String {
        switch error {
        case let error as CredentialResolutionError:
            switch error {
            case .unsupported: return unsupported
            case .needsPastedSecret: return errorNeedsPaste
            case .invalidFormat: return errorInvalidFormat
            case .incompleteSignIn: return errorIncomplete
            case .missingEnvironment(let names): return errorMissingEnvironment(names)
            }
        case let error as CodeRouterError:
            switch error {
            case .notSignedIn: return errorNotSignedIn
            case .scopeChanged: return errorStaleList
            case .timedOut: return errorTimedOut
            case .http, .transport, .decoding: return errorFailed(error.description)
            }
        default:
            return errorFailed(String(describing: error))
        }
    }
}
