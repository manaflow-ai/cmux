import Foundation

/// Refusals of the accounts actions (Resources/Accounts.xcstrings).
enum AccountsAppStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Accounts", bundle: .module)
    }

    static func unknownProvider(_ raw: String) -> String {
        String(format: text("accounts.refusal.unknownProvider", "Unknown provider “%@”."), raw)
    }
    static func unknownAccount(_ id: String) -> String {
        String(format: text("accounts.refusal.unknownAccount", "CodeRouter has no account with the ID “%@”."), id)
    }
    static var noWindow: String { text("accounts.refusal.noWindow", "Open a window first. The sign-in runs in a terminal tab.") }
    static var nothingToSignIn: String { text("accounts.refusal.nothingToSignIn", "This provider has no sign-in.") }
    static var pasteInSettings: String {
        text("accounts.refusal.pasteInSettings", "This provider needs a pasted key or token. Settings > Accounts is open at its paste field.")
    }
    static var unsupported: String { text("accounts.refusal.unsupported", "CodeRouter does not route this provider yet.") }
}
