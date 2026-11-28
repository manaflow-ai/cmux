import Foundation

/// Refusals of the accounts actions (Resources/Accounts.xcstrings).
enum AccountsAppStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Accounts", bundle: .module.inAppLanguage)
    }

    static func unknownProvider(_ raw: String) -> String {
        String(format: text("accounts.refusal.unknownProvider", "Unknown provider “%@”."), raw)
    }
    static var noWindow: String { text("accounts.refusal.noWindow", "Open a window first. The sign-in runs in a terminal tab.") }
    static var nothingToSignIn: String { text("accounts.refusal.nothingToSignIn", "This provider has no sign-in.") }
}
