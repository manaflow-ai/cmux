import CmuxSettings
import Foundation

extension TerminalNotificationPolicyEffects {
    /// Both sidebars receive exactly the same admitted ordering effect and live
    /// setting. `off` never reorders, `notifications` runs `action` at once, and
    /// `agentActivity` routes it through the shared activity throttle.
    @MainActor
    func applySidebarOrdering(
        defaults: UserDefaults,
        workspaceId: UUID,
        controller: WorkspaceActivityReorderController = .shared,
        action: @escaping @MainActor () -> Void
    ) {
        guard reorderWorkspace else { return }
        switch UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().app.reorderOnNotification) {
        case .off:
            return
        case .notifications:
            action()
        case .agentActivity:
            controller.notificationRequestsReorder(workspaceId: workspaceId, move: action)
        }
    }
}
