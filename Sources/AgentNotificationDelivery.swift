import CmuxSettings
import Foundation

enum AgentNotificationDeliveryResult: Sendable, Equatable {
    case gated
    case accepted
    case saturated
}

/// Applies agent notification policy and publishes accepted events through the shared mutation bus.
struct AgentNotificationDelivery: Sendable {
    private let permissionEnabled: Bool
    private let turnMode: AgentTurnCompleteMode
    private let idleEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        let catalog = NotificationsCatalogSection()
        self.permissionEnabled = catalog.agentPermissionPrompt.value(in: defaults)
        self.turnMode = AgentTurnCompleteMode(
            rawValue: catalog.agentTurnComplete.value(in: defaults)
        ) ?? .whenIdle
        self.idleEnabled = catalog.agentIdleReminder.value(in: defaults)
    }

    /// Gates and enqueues the same notification event for hooks and PTY prompt detectors.
    @discardableResult
    func enqueue(
        workspaceID: UUID,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String,
        category: AgentNotifyCategory?,
        pending: Bool
    ) -> AgentNotificationDeliveryResult {
        if let category,
           !agentNotificationShouldDeliver(
               category: category,
               pending: pending,
               permissionEnabled: permissionEnabled,
               turnMode: turnMode,
               idleEnabled: idleEnabled
           ) {
            return .gated
        }
        let accepted = TerminalMutationBus.shared.enqueueNotification(
            tabId: workspaceID,
            surfaceId: surfaceID,
            title: title,
            subtitle: subtitle,
            body: body
        )
        return accepted ? .accepted : .saturated
    }
}
