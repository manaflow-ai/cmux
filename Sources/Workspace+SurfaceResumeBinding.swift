import Foundation

/// Centralizes surface-resume binding publication so context-health state sees
/// every session-generation change through the same mutation path.
extension Workspace {
    func updateSurfaceResumeBinding(
        panelId: UUID,
        to binding: SurfaceResumeBindingSnapshot?,
        notifyWhenUnchanged: Bool = false,
        notifyContextManagement: Bool = true
    ) {
        let previous = surfaceResumeBindingsByPanelId[panelId]
        if let binding {
            surfaceResumeBindingsByPanelId[panelId] = binding
        } else {
            surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        }
        if notifyContextManagement, notifyWhenUnchanged || previous != binding {
            contextManagementBindingDidChange(panelId: panelId)
        }
    }

    /// Removes every binding through the same lifecycle notification path used
    /// for individual session-generation changes.
    func removeAllSurfaceResumeBindings(keepingCapacity: Bool = false) {
        let panelIds = Array(surfaceResumeBindingsByPanelId.keys)
        surfaceResumeBindingsByPanelId.removeAll(keepingCapacity: keepingCapacity)
        for panelId in panelIds {
            contextManagementBindingDidChange(panelId: panelId)
        }
    }

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
