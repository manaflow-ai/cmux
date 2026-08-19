import Foundation

/// Shared mutation path for Workspace- and Dock-owned resume bindings.
@MainActor
protocol SurfaceResumeBindingOwning: AnyObject {
    var surfaceResumeBindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] { get set }

    func contextManagementBindingDidChange(panelId: UUID)
}

extension SurfaceResumeBindingOwning {
    /// Updates one effective binding and publishes real or explicitly forced
    /// ownership changes to context management.
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

    /// Removes every effective binding through the shared notification path.
    func removeAllSurfaceResumeBindings(keepingCapacity: Bool = false) {
        let panelIds = Array(surfaceResumeBindingsByPanelId.keys)
        surfaceResumeBindingsByPanelId.removeAll(keepingCapacity: keepingCapacity)
        for panelId in panelIds {
            contextManagementBindingDidChange(panelId: panelId)
        }
    }
}
