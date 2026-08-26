import Foundation

extension TabManager {
    /// Applies the live retention cap to every workspace owned by this manager.
    func applyLinksRetentionLimit(_ limit: Int) {
        for workspace in tabs {
            workspace.linksState.applyRetentionLimit(limit)
        }
    }
}
