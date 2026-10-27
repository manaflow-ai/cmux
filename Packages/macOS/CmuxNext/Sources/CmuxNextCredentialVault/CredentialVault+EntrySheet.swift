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

    public static func entrySheet(_ request: EntryRequest) -> CmuxDialogSpec {
        var lines = [CredentialVaultStrings.entryAsks(request.requester, request.name)]
        if let reason = request.reason, !reason.isEmpty { lines.append(CredentialVaultStrings.entryReason(reason)) }
        lines.append(CredentialVaultStrings.entryPrivacy)
        return CmuxDialogSpec(
            title: request.replaces ? CredentialVaultStrings.entryReplaceTitle(request.name) : CredentialVaultStrings.entryTitle(request.name),
            lines: lines,
            fields: [.text(id: entryValueField, label: CredentialVaultStrings.entryValueLabel, initial: "", placeholder: nil, secure: true),
                     .check(id: entryAgentsField, title: CredentialVaultStrings.entryAgentsCheck, on: true)],
            buttons: [.cancel(CredentialVaultStrings.entryCancel),
                      CmuxDialogButton(id: entrySaveButton, title: CredentialVaultStrings.entrySave, role: .default)],
            identifier: entrySheetIdentifier)
    }

    /// The person's value and scope; nil when they cancelled, closed it or left the field empty.
    public static func entryAnswer(_ answer: CmuxDialogAnswer) -> EntryAnswer? {
        guard !answer.isDismissal, answer.button == entrySaveButton,
              let value = answer.text(entryValueField), !value.isEmpty else { return nil }
        return EntryAnswer(value: value, scope: answer.isOn(entryAgentsField) ? [.user, .agents] : [.user])
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
        return entryAnswer(result)
    }

    /// The sheet's dialog id, for a dismissal when the request ends first.
    @MainActor private final class ShownSheet: Sendable {
        var id: Int?
    }
}
