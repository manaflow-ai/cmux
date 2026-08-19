import Foundation

/// Uses the shared effective-binding mutation and notification path.
extension Workspace: SurfaceResumeBindingOwning {
    /// Retains bindings for live panels and returns the panel ids removed.
    @discardableResult
    func removeSurfaceResumeBindings(except validPanelIds: Set<UUID>) -> Set<UUID> {
        let removedPanelIds = Set(surfaceResumeBindingsByPanelId.keys).subtracting(validPanelIds)
        for panelId in removedPanelIds {
            updateSurfaceResumeBinding(panelId: panelId, to: nil)
        }
        return removedPanelIds
    }
}
