import Foundation

extension TabManager {
    func liveStableIdentitySet() -> Set<UUID> {
        var identities: Set<UUID> = []
        for workspace in tabs {
            identities.insert(workspace.stableId)
            for panel in workspace.panels.values {
                identities.insert(panel.stableSurfaceId)
            }
        }
        return identities
    }
}
