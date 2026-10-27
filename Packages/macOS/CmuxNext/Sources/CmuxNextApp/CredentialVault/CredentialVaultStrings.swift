import Foundation

/// The vault's text (Resources/CredentialVault.xcstrings): refusals over the socket, the audit log's
/// caller names, and the secure entry sheet.
nonisolated enum CredentialVaultStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "CredentialVault", bundle: .module)
    }

    // MARK: Callers (audit log)

    static var you: String { text("credentialVault.caller.you", "you") }
    static var chief: String { text("credentialVault.caller.chief", "the Chief") }
    static func agentSession(_ id: String) -> String { String(format: text("credentialVault.caller.agentSession", "agent session %@"), id) }
    static func terminal(_ id: String) -> String { String(format: text("credentialVault.caller.terminal", "terminal %@"), id) }
    static func personAskedBy(_ asker: String) -> String { String(format: text("credentialVault.caller.personAskedBy", "you, asked by %@"), asker) }

    // MARK: Refusals

    static var unavailable: String { text("credentialVault.error.unavailable", "The vault is not available in this app.") }
    static func missingParam(_ method: String, _ key: String) -> String {
        String(format: text("credentialVault.error.missingParam", "%1$@ requires params.%2$@"), method, key)
    }
    static func mustBeString(_ key: String) -> String { String(format: text("credentialVault.error.mustBeString", "%@ must be a string"), key) }
    static var namesMustBeStrings: String { text("credentialVault.error.namesMustBeStrings", "names must be an array of secret names") }
    static var callerMustBeObject: String { text("credentialVault.error.callerMustBeObject", "caller must be an object") }
    static var badScope: String { text("credentialVault.error.badScope", "scope must name user, agents or both") }
    static func invalidName(_ name: String) -> String {
        String(format: text("credentialVault.error.invalidName", "“%@” is not a vault name: use letters, digits and _, not starting with a digit (at most 128)."), name)
    }
    static func invalidValue(_ name: String) -> String {
        String(format: text("credentialVault.error.invalidValue", "The value for %@ must be 1 byte to 64 KB of text without NUL bytes."), name)
    }
    static var invalidNote: String { text("credentialVault.error.invalidNote", "A note is at most 200 characters.") }
    static func missing(_ names: [String]) -> String {
        String(format: text("credentialVault.error.missing", "The vault has no %@. Add it with `cmux vault set NAME`, or ask the person with `cmux vault request NAME`."),
               names.joined(separator: ", "))
    }
    static func denied(_ names: [String], consumer: CredentialVault.Consumer) -> String {
        let format = consumer == .agents
            ? text("credentialVault.error.deniedAgents", "Agents may not use %@: its scope is you only. Change it in Settings > Credential Vault.")
            : text("credentialVault.error.deniedUser", "%@ is for agents only. Change its scope in Settings > Credential Vault.")
        return String(format: format, names.joined(separator: ", "))
    }
    static var agentsMayNotWrite: String {
        text("credentialVault.error.agentsMayNotWrite", "Only you add, change or remove vault secrets. An agent asks with `cmux vault request NAME`.")
    }
    static func keychain(_ status: Int32) -> String { String(format: text("credentialVault.error.keychain", "The Keychain refused (%d)."), status) }
    static func index(_ path: String) -> String {
        String(format: text("credentialVault.error.index", "The vault index at %@ cannot be read or written."), path)
    }
    static func declined(_ name: String) -> String {
        String(format: text("credentialVault.error.declined", "%@ was not added: the request was declined or closed."), name)
    }

    // MARK: Secure entry sheet

    static func entryTitle(_ name: String) -> String { String(format: text("credentialVault.entry.title", "Add %@ to the Credential Vault"), name) }
    static func entryReplaceTitle(_ name: String) -> String { String(format: text("credentialVault.entry.replaceTitle", "Replace %@ in the Credential Vault"), name) }
    static func entryAsks(_ asker: String, _ name: String) -> String {
        String(format: text("credentialVault.entry.asks", "%1$@ asks for %2$@."), asker, name)
    }
    static func entryReason(_ reason: String) -> String { String(format: text("credentialVault.entry.reason", "Reason: %@"), reason) }
    static var entryPrivacy: String {
        text("credentialVault.entry.privacy", "The value goes to your Keychain. Agents use it by name and never see it.")
    }
    static var entryValueLabel: String { text("credentialVault.entry.valueLabel", "Value") }
    static var entryAgentsCheck: String { text("credentialVault.entry.agentsCheck", "Agents may use it") }
    static var entrySave: String { text("credentialVault.entry.save", "Save") }
    static var entryCancel: String { text("credentialVault.entry.cancel", "Cancel") }
}
