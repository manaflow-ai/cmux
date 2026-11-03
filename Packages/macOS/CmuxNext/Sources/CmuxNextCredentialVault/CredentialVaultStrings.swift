import Foundation

/// The vault's text (Resources/CredentialVault.xcstrings): refusals over the socket, the audit log's
/// caller names, and the secure entry sheet.
nonisolated enum CredentialVaultStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "CredentialVault", bundle: .module)
    }

    static var rolloutTitle: String { text("credentialVault.rollout.title", "Credential Vault") }
    static var disabled: String { text("credentialVault.rollout.disabled", "Enable Credential Vault in Debug Settings to use it.") }

    // MARK: Callers (audit log)

    static var you: String { text("credentialVault.caller.you", "you") }
    static var chief: String { text("credentialVault.caller.chief", "the Chief") }
    static func agentSession(_ id: String) -> String { String(format: text("credentialVault.caller.agentSession", "agent session %@"), id) }
    static func terminal(_ id: String) -> String { String(format: text("credentialVault.caller.terminal", "terminal %@"), id) }
    static func personAskedBy(_ asker: String) -> String { String(format: text("credentialVault.caller.personAskedBy", "you, asked by %@"), asker) }

    // MARK: Refusals

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
    static func entryReason(_ reason: String) -> String {
        String(format: text("credentialVault.entry.reason", "Its reason, in its own words: “%@”"), reason)
    }
    static var entryPrivacy: String {
        text("credentialVault.entry.privacy", "The value goes to your Keychain. Agents use it by name and never see it.")
    }
    static var entryFromMessage: String {
        text("credentialVault.entry.fromMessage", "Your message holds this key. Save it here and the message names it instead.")
    }
    static var entryPasteTitle: String { text("credentialVault.entry.pasteTitle", "Move a Key to the Credential Vault") }
    static var entryNameLabel: String { text("credentialVault.entry.nameLabel", "Name") }
    /// A socket asker that did not say it is an agent: the sheet never reads as the person's own.
    static var cmuxCommand: String { text("credentialVault.caller.cmuxCommand", "a cmux command on this Mac") }
    static var approvalOpen: String {
        text("credentialVault.error.approvalOpen", "Another Credential Vault approval is open in cmux; answer it first")
    }
    static var approvalCooldown: String {
        text("credentialVault.error.cooldown", "You just declined a Credential Vault request in cmux; ask again in a few seconds")
    }
    static var homeChat: String { text("credentialVault.caller.homeChat", "you, from a chat message") }
    static var entryValueLabel: String { text("credentialVault.entry.valueLabel", "Value") }
    static var entryAgentsCheck: String { text("credentialVault.entry.agentsCheck", "Agents may use it") }
    static var entrySave: String { text("credentialVault.entry.save", "Save") }
    static var entryAddTitle: String { text("credentialVault.entry.addTitle", "Add a Credential") }
    static var settingsCaller: String { text("credentialVault.caller.settings", "you, in Settings") }
    static func alreadyThere(_ name: String) -> String {
        String(format: text("credentialVault.error.exists", "The vault already has %@. Use its Replace to change the value."), name)
    }
    static func nameTaken(_ name: String) -> String {
        String(format: text("credentialVault.entry.nameTaken", "The vault already has %@. Choose another name, or cancel and use its Replace in Settings."), name)
    }
    // MARK: Approval (a socket call only the person may make)

    static var approveAllow: String { text("credentialVault.approve.allow", "Allow") }
    static func approveUseTitle(_ names: String) -> String {
        String(format: text("credentialVault.approve.useTitle", "Allow a command to use %@?"), names)
    }
    static func approveProgram(_ program: String) -> String {
        String(format: text("credentialVault.approve.program", "It says it will run: %@"), program)
    }
    static var approveUseLine: String {
        text("credentialVault.approve.useLine", "It is kept for you: agents may not use it. The program that asks gets its value.")
    }
    static func approveStoreTitle(_ name: String) -> String {
        String(format: text("credentialVault.approve.storeTitle", "Save %@ to the Credential Vault?"), name)
    }
    static var approveStoreLine: String {
        text("credentialVault.approve.storeLine", "The value comes from the program that asks, not from you.")
    }
    static func approveReplaceTitle(_ name: String) -> String {
        String(format: text("credentialVault.approve.replaceTitle", "Replace the value of %@ in the Credential Vault?"), name)
    }
    static func approveScopeTitle(_ name: String) -> String {
        String(format: text("credentialVault.approve.scopeTitle", "Change who may use %@?"), name)
    }
    static func approveScopeLine(_ scope: [CredentialVault.Consumer]) -> String {
        switch (scope.contains(.user), scope.contains(.agents)) {
        case (true, true): text("credentialVault.approve.scopeBoth", "New: you and agents.")
        case (false, true): text("credentialVault.approve.scopeAgents", "New: agents only.")
        default: text("credentialVault.approve.scopeUser", "New: only you. Agents may not use it.")
        }
    }
    static var approveOnlyYou: String {
        text("credentialVault.approve.onlyYou", "A `cmux vault` command asks for this. Allow it only if you just ran that command yourself.")
    }
    static func declinedApproval(_ name: String) -> String {
        String(format: text("credentialVault.error.notApproved", "%@: not allowed in cmux, nothing changed"), name)
    }

    static func deleteTitle(_ name: String) -> String {
        String(format: text("credentialVault.delete.title", "Delete %@ from the Credential Vault?"), name)
    }
    static var deleteLine: String {
        text("credentialVault.delete.line", "Agents and commands that use it stop getting it. Its value leaves your Keychain.")
    }
    static var deleteButton: String { text("credentialVault.delete.button", "Delete") }
    static var entryCancel: String { text("credentialVault.entry.cancel", "Cancel") }
}
