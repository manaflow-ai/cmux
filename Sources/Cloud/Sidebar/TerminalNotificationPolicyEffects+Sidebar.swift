import CmuxSettings
import Foundation

extension TerminalNotificationPolicyEffects {
    /// Both sidebars receive exactly the same admitted ordering effect and live
    /// setting. `off` never reorders. `notifications` raises the Cloud row and
    /// moves the local workspace at once. `agentActivity` raises the Cloud row
    /// at once but routes the local move through the shared activity throttle,
    /// which moves the workspace itself.
    @MainActor
    func applySidebarOrdering(
        defaults: UserDefaults,
        workspaceId: UUID,
        controller: WorkspaceActivityReorderController? = nil,
        raiseCloudRow: () -> Void,
        moveLocalWorkspace: () -> Void
    ) {
        guard reorderWorkspace else { return }
        switch UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().app.reorderOnNotification) {
        case .off:
            return
        case .notifications:
            moveLocalWorkspace()
            raiseCloudRow()
        case .agentActivity:
            raiseCloudRow()
            (controller ?? .shared).notificationRequestsReorder(workspaceId: workspaceId)
        }
    }
}
