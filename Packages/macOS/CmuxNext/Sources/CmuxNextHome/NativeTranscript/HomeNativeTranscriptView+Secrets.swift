public import AppKit
public import CmuxNextCredentialVault
import CmuxNextCompat

extension HomeNativeTranscriptView {
    /// The vault rollout owns both the paste offer and secret draft filtering. Off restores Home's usual send.
    /// Applied now, then again each time the rollout setting changes.
    public func connectCredentialVault(vault: CredentialVault, window: @escaping @MainActor @Sendable () -> NSWindow?) {
        applyCredentialVault(CredentialVault.isRolloutEnabled, vault: vault, window: window)
        credentialVaultFollower?.cancel()
        // task-owner: one loop per transcript view; it ends when the view is gone or connects again
        credentialVaultFollower = Task { [weak self] in
            for await enabled in ObservationStream({ CredentialVault.isRolloutEnabled }) {
                guard let self, !Task.isCancelled else { return }
                self.applyCredentialVault(enabled, vault: vault, window: window)
            }
        }
    }

    private func applyCredentialVault(_ enabled: Bool, vault: CredentialVault, window: @escaping @MainActor @Sendable () -> NSWindow?) {
        guard enabled else {
            secretHost = nil
            return
        }
        secretHost = { findings in
            guard let window = window() else { return nil }
            var moved: [(value: String, name: String)] = []
            for finding in findings {
                switch await vault.movePasted(finding.value, suggestedName: finding.suggestedName, in: window) {
                case .moved(let name): moved.append((finding.value, name))
                case .cancelled: continue
                case .failed: return moved.isEmpty ? nil : moved
                }
            }
            return moved
        }
    }
}
