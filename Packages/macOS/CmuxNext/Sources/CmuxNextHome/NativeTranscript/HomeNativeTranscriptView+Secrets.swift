import AppKit
import CmuxNextCredentialVault
import Observation

extension HomeNativeTranscriptView {
    /// The vault rollout owns both the paste offer and secret draft filtering. Off restores Home's usual send.
    public func connectCredentialVault(vault: CredentialVault, window: @escaping @MainActor @Sendable () -> NSWindow?) {
        withObservationTracking {
            if CredentialVault.rolloutEnabled.value {
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
            } else {
                secretHost = nil
            }
        } onChange: { [weak self] in
            // task-owner: refresh this transcript's single gate dependency; a released view is not retained
            Task { @MainActor [weak self] in self?.connectCredentialVault(vault: vault, window: window) }
        }
    }
}
