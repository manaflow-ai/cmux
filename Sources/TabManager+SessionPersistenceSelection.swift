import Foundation

extension TabManager {
    /// Hashes the bounded workspace projection that decides which windows can
    /// enter a session snapshot. Persisted windows receive the full autosave
    /// fingerprint separately.
    func combineSessionPersistenceSelectionMetadata(
        into hasher: inout Hasher,
        restorableAgentIndex: RestorableAgentSessionIndex,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex
    ) {
        hasher.combine(tabs.count)
        hasher.combine(tabs.allSatisfy(\.isRemoteTmuxMirror))

        let restorableWorkspaces = Array(
            tabs.lazy
                .filter(\.isRestorableInSessionSnapshot)
                .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
        )
        hasher.combine(restorableWorkspaces.count)
        for workspace in restorableWorkspaces {
            workspace.combineSessionPersistenceSelectionMetadata(
                into: &hasher,
                restorableAgentIndex: restorableAgentIndex,
                surfaceResumeBindingIndex: surfaceResumeBindingIndex
            )
        }
    }
}
