import Foundation

/// Shared mutation path for Workspace- and Dock-owned resume bindings.
@MainActor
protocol SurfaceResumeBindingOwning: AnyObject {
    var surfaceResumeBindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] { get set }
    /// The concrete owner used by shared context-management forwarding.
    var contextManagementOwner: AgentContextManagementCoordinator.PanelOwner { get }

    func contextManagementBindingDidChange(panelId: UUID)
    func contextManagementBindingsDidChange(panelIds: [UUID])
}

extension SurfaceResumeBindingOwning {
    func contextManagementLifecycleDidChange(
        key: String,
        panelId: UUID,
        lifecycle: AgentHibernationLifecycleState
    ) {
        AppDelegate.shared?.agentContextManagementCoordinator.lifecycleDidChange(
            key: key,
            panelId: panelId,
            lifecycle: lifecycle
        )
    }

    func contextManagementLifecycleDidClear(key: String? = nil, panelId: UUID) {
        AppDelegate.shared?.agentContextManagementCoordinator.lifecycleDidClear(
            key: key,
            panelId: panelId
        )
    }

    func contextManagementBindingDidChange(panelId: UUID) {
        AppDelegate.shared?.agentContextManagementCoordinator.bindingDidChange(panelId: panelId)
    }

    func contextManagementBindingsDidChange(panelIds: [UUID]) {
        guard let coordinator = AppDelegate.shared?.agentContextManagementCoordinator else { return }
        coordinator.bindingDidChange(
            panelIds: panelIds,
            owner: contextManagementOwner
        )
    }

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
        if !panelIds.isEmpty {
            contextManagementBindingsDidChange(panelIds: panelIds)
        }
    }
}
