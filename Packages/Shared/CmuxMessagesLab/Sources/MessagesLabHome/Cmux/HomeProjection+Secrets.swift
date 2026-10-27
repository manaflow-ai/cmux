import Foundation

/// Where the host moves credentials found in a send (cmux: the Credential Vault's secure sheet,
/// cmux issue 26412). Answers, for each finding the person saved, its value and the vault name it
/// went under; nil or empty when they moved none.
public typealias HomeSecretHost = @MainActor ([HomeSecretScan.Finding]) async -> [(value: String, name: String)]?

/// A send whose text holds an API key or token (``HomeSecretScan``) is held: the text stays in the
/// field, a notice says why, and the host offers to move each one to the vault. What the person
/// moves becomes `[vault:NAME]` in the field, so the next Return sends the message without it. A
/// second Return on the same text sends it as typed (the person chose to).
extension HomeProjection {
    func holdsSecret(_ draft: Draft) -> Bool {
        guard let host = secretHost else { return false }
        if secretWarnedDraft == draft.text {
            secretWarnedDraft = nil
            return false
        }
        let findings = HomeSecretScan().findings(in: draft.plainText)
        guard !findings.isEmpty else { return false }
        secretWarnedDraft = draft.text
        sendNotice = CmuxStrings.secretHeld
        // task-owner: one vault offer; ends when the person answers the sheet
        Task { @MainActor [weak self] in
            let moved = await host(findings) ?? []
            guard let self, !self.stopped, let store = self.controller.store, !moved.isEmpty else { return }
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
