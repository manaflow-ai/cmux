import Foundation

/// The missing-access card's native strings (Resources/Accounts.xcstrings).
nonisolated struct AgentPaneAccessStrings {
    static func keyTitle(_ provider: String) -> String {
        String(format: String(localized: "access.key.title", defaultValue: "Add your %@ key", table: "Accounts", bundle: .module), provider)
    }

    static func keyMessage(_ provider: String) -> String {
        String(format: String(localized: "access.key.message",
                              defaultValue: "The key stays in this Mac's Keychain. cmux sends it only to %@, for this harness's chats.",
                              table: "Accounts", bundle: .module), provider)
    }

    static var keySave: String { String(localized: "access.key.save", defaultValue: "Save Key", table: "Accounts", bundle: .module) }
    static var keyCancel: String { String(localized: "access.key.cancel", defaultValue: "Cancel", table: "Accounts", bundle: .module) }
    static var keyPlaceholder: String {
        String(localized: "access.key.placeholder", defaultValue: "Paste the API key", table: "Accounts", bundle: .module)
    }

    static var keyUnsupported: String {
        String(localized: "access.key.unsupported",
               defaultValue: "This harness takes no API key from cmux. Sign in to it, or use cmux credits.", table: "Accounts", bundle: .module)
    }

    static var keychainFailed: String {
        String(localized: "access.key.keychainFailed", defaultValue: "The key could not be saved to the Keychain.", table: "Accounts", bundle: .module)
    }

    static var noAgentService: String {
        String(localized: "access.noAgentService", defaultValue: "The agent service is not running. Try again in a moment.",
               table: "Accounts", bundle: .module)
    }

    static var notSignedIn: String {
        String(localized: "access.credits.notSignedIn", defaultValue: "Sign in to cmux to use cmux credits.", table: "Accounts", bundle: .module)
    }

    static var billingFailed: String {
        String(localized: "access.credits.billingFailed", defaultValue: "cmux couldn't open the payment page. Try again in a minute.",
               table: "Accounts", bundle: .module)
    }
}
