import AppKit
import CmuxNextDesign

/// The vault's secure entry (cmux issue 26412): a cmux dialog with a hidden field, shown on the
/// active window when the Chief or an agent asks for a secret (`cmux vault request`), from
/// Settings > Credential Vault's Add, and from the Home composer's "move this key to the vault". The value
/// goes from the field to the Keychain; it never enters a chat, a transcript or a log. Only the
/// person answers it: `debug.dialog` may not type into it or press its buttons
/// (``DebugDialog/userOnly``) and never reports its field (``DebugDialog/secureFields``).
@MainActor
enum CredentialVaultEntrySheet {
    static let identifier = "cmux.dialog.credentialVault.entry"
    static let valueField = "value"
    static let agentsField = "agents"
    static let saveButton = "save"

    static func spec(_ request: CredentialVaultControl.EntryRequest, initialValue: String = "") -> CmuxDialogSpec {
        var lines = [CredentialVaultStrings.entryAsks(request.requester, request.name)]
        if let reason = request.reason, !reason.isEmpty { lines.append(CredentialVaultStrings.entryReason(reason)) }
        lines.append(CredentialVaultStrings.entryPrivacy)
        return CmuxDialogSpec(
            title: request.replaces ? CredentialVaultStrings.entryReplaceTitle(request.name) : CredentialVaultStrings.entryTitle(request.name),
            lines: lines,
            fields: [.text(id: valueField, label: CredentialVaultStrings.entryValueLabel, initial: initialValue, placeholder: nil, secure: true),
                     .check(id: agentsField, title: CredentialVaultStrings.entryAgentsCheck, on: true)],
            buttons: [.cancel(CredentialVaultStrings.entryCancel), CmuxDialogButton(id: saveButton, title: CredentialVaultStrings.entrySave, role: .default)],
            identifier: identifier)
    }

    /// The person's value and scope; nil when they cancelled, closed it, left the field empty, or
    /// no window can show it.
    static func answer(_ answer: CmuxDialogAnswer) -> CredentialVaultControl.EntryAnswer? {
        guard !answer.isDismissal, answer.button == saveButton,
              let value = answer.text(valueField), !value.isEmpty else { return nil }
        return CredentialVaultControl.EntryAnswer(value: value, scope: answer.isOn(agentsField) ? [.user, .agents] : [.user])
    }

    /// Asks on the active window (`initialValue`: a key the composer found, so the person only
    /// confirms). Ends with nil when the asking task is cancelled (the request's connection closed).
    static func ask(_ request: CredentialVaultControl.EntryRequest, initialValue: String = "", services: AppServices) async -> CredentialVaultControl.EntryAnswer? {
        guard let window = services.windows.active?.window, !Task.isCancelled else { return nil }
        let shown = UserOnlySettingConfirmation.ShownDialog()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                shown.id = CmuxDialogCenter.shared.present(spec(request, initialValue: initialValue), in: .window(window)) {
                    continuation.resume(returning: $0)
                }
            }
        } onCancel: {
            Task { @MainActor in if let id = shown.id { _ = CmuxDialogCenter.shared.dismiss(id) } }
        }
        return answer(result)
    }
}
