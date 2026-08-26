import Foundation

extension TabManager {
    /// Applies live Links settings to every workspace owned by this manager.
    func applyLinksSettings(retentionLimit: Int, fetchTitlesEnabled: Bool) {
        for workspace in tabs {
            workspace.linksState.applySettings(
                retentionLimit: retentionLimit,
                fetchTitlesEnabled: fetchTitlesEnabled
            )
        }
    }
}
