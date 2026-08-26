import Foundation

extension TabManager {
    /// Applies live Links settings to every workspace owned by this manager.
    func applyLinksSettings(retentionLimit: Int, fetchTitlesEnabled: Bool) {
        let clampedRetentionLimit = WorkspaceLinksIngestConfiguration.clampedRetentionLimit(
            retentionLimit
        )
        for workspace in tabs where
            workspace.linksState.retentionLimit != clampedRetentionLimit ||
            workspace.linksState.fetchTitlesEnabled != fetchTitlesEnabled {
            workspace.linksState.applySettings(
                retentionLimit: clampedRetentionLimit,
                fetchTitlesEnabled: fetchTitlesEnabled
            )
        }
    }
}
