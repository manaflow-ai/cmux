import Foundation

/// Centralizes Dock-owned surface-resume binding publication so context-health
/// state sees every session-generation change through one mutation path.
extension DockSplitStore {
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

    /// Removes every Dock binding through the same lifecycle notification path
    /// used for individual session-generation changes.
    func removeAllSurfaceResumeBindings(keepingCapacity: Bool = false) {
        let panelIds = Array(surfaceResumeBindingsByPanelId.keys)
        surfaceResumeBindingsByPanelId.removeAll(keepingCapacity: keepingCapacity)
        for panelId in panelIds {
            contextManagementBindingDidChange(panelId: panelId)
        }
    }
}
