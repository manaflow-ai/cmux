import Foundation

@MainActor
extension Workspace {
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
        AppDelegate.shared?.agentContextManagementCoordinator.lifecycleDidClear(key: key, panelId: panelId)
    }

    func contextManagementBindingDidChange(panelId: UUID) {
        AppDelegate.shared?.agentContextManagementCoordinator.bindingDidChange(panelId: panelId)
    }
}
