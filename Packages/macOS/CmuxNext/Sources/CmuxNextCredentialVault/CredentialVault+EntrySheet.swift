public import AppKit
public import CmuxNextDesign
public import CmuxNextDesignTokens

/// The vault's secure entry (cmux issue 26412): a cmux dialog with a hidden field, shown on the
/// active window when the Chief or an agent asks for a secret (`cmux vault request`) and from
/// Settings > Credential Vault's Add. The value goes from the field to the Keychain; it never
/// enters a chat, a transcript or a log. Only the person answers it: the App's `debug.dialog` may
/// not type into it or press its buttons, and never reports its hidden field.
extension CredentialVault {
    public static let entrySheetIdentifier = "cmux.dialog.credentialVault.entry"
    public static let entryValueField = "value"
    public static let entryAgentsField = "agents"
    public static let entrySaveButton = "save"
    public static let entryNameField = "name"

    /// The sheet for a key the person pasted into a message, under `suggestedName` until they rename it.
    public static func pasteRequest(suggestedName: String, value: String) -> EntryRequest {
        EntryRequest(name: suggestedName, reason: nil, requester: CredentialVaultStrings.homeChat, replaces: false, pasted: value)
    }

    /// Whether the sheet asks for the name: a pasted key (named by a guess from its shape) or Settings' Add.
    static func asksName(_ request: EntryRequest) -> Bool {
        !request.pasted.isEmpty || request.name.isEmpty || request.taken
    }

    public static func entrySheet(_ request: EntryRequest) -> CmuxDialogSpec {
        let pasted = !request.pasted.isEmpty
        var lines: [String] = []
        if pasted {
            lines.append(CredentialVaultStrings.entryFromMessage)
        } else if !request.name.isEmpty, !request.requester.isEmpty {
            lines.append(CredentialVaultStrings.entryAsks(request.requester, request.name))
        }
        if let reason = request.reason, !reason.isEmpty { lines.append(CredentialVaultStrings.entryReason(reason)) }
        if request.taken { lines.append(CredentialVaultStrings.nameTaken(request.name)) }
        lines.append(CredentialVaultStrings.entryPrivacy)
        var fields: [CmuxDialogField] = []
        // A pasted key's name is the person's to choose (a guess from its shape); an agent's request names it.
        if asksName(request) { fields.append(.text(id: entryNameField, label: CredentialVaultStrings.entryNameLabel, initial: request.name, placeholder: nil, secure: false)) }
        fields += [.text(id: entryValueField, label: CredentialVaultStrings.entryValueLabel, initial: request.typed.isEmpty ? request.pasted : request.typed,
                                     placeholder: nil, secure: true),
                   .check(id: entryAgentsField, title: CredentialVaultStrings.entryAgentsCheck, on: request.scope.contains(.agents))]
        // A sheet a socket call opened takes the value only from the person's typing after their
        // click: the field is not focused when it appears and Save takes no key.
        let save = request.unprompted
            ? CmuxDialogButton(id: entrySaveButton, title: CredentialVaultStrings.entrySave, clickOnly: true)
            : CmuxDialogButton(id: entrySaveButton, title: CredentialVaultStrings.entrySave, role: .default)
        return CmuxDialogSpec(
            title: pasted ? CredentialVaultStrings.entryPasteTitle
                : request.name.isEmpty || request.taken ? CredentialVaultStrings.entryAddTitle
                : request.replaces ? CredentialVaultStrings.entryReplaceTitle(request.name) : CredentialVaultStrings.entryTitle(request.name),
            lines: lines,
            fields: fields,
            buttons: [.cancel(CredentialVaultStrings.entryCancel), save],
            identifier: entrySheetIdentifier, focusesField: !request.unprompted)
    }

    /// The person's name, value and scope; nil when they cancelled, closed it, left the value empty
    /// or typed a name the vault does not take.
    public static func entryAnswer(_ answer: CmuxDialogAnswer, request: EntryRequest) -> EntryAnswer? {
        guard !answer.isDismissal, answer.button == entrySaveButton,
              let value = answer.text(entryValueField), !value.isEmpty else { return nil }
        let name = !asksName(request) ? request.name
            : (answer.text(entryNameField) ?? request.name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(name) else { return nil }
        // The box sets agents; the request's other consumers stay, and a scope left empty is the person's.
        var scope = request.scope.filter { $0 != .agents }
        if answer.isOn(entryAgentsField) { scope.append(.agents) }
        return EntryAnswer(name: name, value: value, scope: scope.isEmpty ? [.user] : scope)
    }

    /// Asks on `window`. Ends with nil when the asking task is cancelled (the request's connection
    /// closed or its deadline passed): the sheet goes, nothing is stored.
    @MainActor
    public static func askForEntry(_ request: EntryRequest, in window: NSWindow) async -> EntryAnswer? {
        guard !Task.isCancelled else { return nil }
        let shown = ShownSheet()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                shown.id = CmuxDialogCenter.shared.present(entrySheet(request), in: .window(window)) {
                    continuation.resume(returning: $0)
                }
            }
        } onCancel: {
            Task { @MainActor in if let id = shown.id { _ = CmuxDialogCenter.shared.dismiss(id) } }
        }
        return entryAnswer(result, request: request)
    }

    /// The sheet's dialog id, for a dismissal when the request ends first.
    @MainActor private final class ShownSheet: Sendable {
        var id: Int?
    }
}
