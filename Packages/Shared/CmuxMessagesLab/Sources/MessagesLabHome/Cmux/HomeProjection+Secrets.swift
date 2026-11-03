import Foundation

/// Where the host moves credentials found in a send (cmux: the Credential Vault's secure sheet,
/// cmux issue 26412). Answers, for each finding the person saved, its value and the vault name it
/// went under (empty: they answered and moved none); nil when it could not ask them or the vault
/// failed before anything moved, so the send stays held.
public typealias HomeSecretHost = @MainActor ([HomeSecretScan.Finding]) async -> [(value: String, name: String)]?

/// A send whose text holds an API key or token (``HomeSecretScan``) is held: the text stays in the
/// field, a notice says why, and the host offers to move each one to the vault. What the person
/// moves becomes `[vault:NAME]` in the field, so the next Return sends the message without it.
/// Nothing goes out while the offer is open (a double Return, a Return that lands while its sheet
/// opens), nor when it could not be shown. Once the person answered and moved nothing, a Return on
/// the same text sends it as typed (the person chose to).
extension HomeProjection {
    func holdsSecret(_ draft: Draft) -> Bool {
        guard let host = secretHost else { return false }
        if secretOfferOpen { return true }
        if secretWarnedDraft == draft.text { return false }
        let findings = HomeSecretScan().findings(in: draft.plainText)
        guard !findings.isEmpty else { return false }
        secretOfferOpen = true
        sendNotice = CmuxStrings.secretHeld
        let held = draft.text
        // task-owner: one vault offer; ends when the person answers the sheet
        Task { @MainActor [weak self] in
            let answer = await host(findings)
            guard let self else { return }
            self.secretOfferOpen = false
            guard !self.stopped, let store = self.controller.store else { return }
            // Not asked (no window) or the vault failed: still held; the person removes the key to send.
            guard let moved = answer else {
                self.sendNotice = CmuxStrings.secretNotOffered
                return
            }
            guard !moved.isEmpty else {
                self.secretWarnedDraft = held
                return
            }
            var text = store.state.ui.draft.text
            for item in moved { text = HomeSecretScan.redacted(text, value: item.value, name: item.name) }
            self.controller.dispatch(.setDraft(text))
            self.secretWarnedDraft = nil
            self.sendNotice = CmuxStrings.secretMoved(moved.map(\.name))
            self.saveDraft()
        }
        return true
    }
}
