import CmuxSettings
import Foundation

enum AgentNotificationDeliveryResult: Sendable, Equatable {
    case gated
    case accepted
    case saturated
    case cancelled
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

    /// Internal delivery path. One serial GCD worker owns capacity waiting, so
    /// actor executors stay free and producers remain ordered behind it.
    func enqueueReliably(
        workspaceID: UUID,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String,
        category: AgentNotifyCategory?,
        pending: Bool,
        allowWorkspaceFallbackForValidatedSurface: Bool = false
    ) async -> AgentNotificationDeliveryResult {
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
        let result = await TerminalMutationBus.shared.enqueueNotificationReliably(
            tabId: workspaceID,
            surfaceId: surfaceID,
            title: title,
            subtitle: subtitle,
            body: body,
            allowWorkspaceFallbackForValidatedSurface: allowWorkspaceFallbackForValidatedSurface
        )
        switch result {
        case .accepted:
            return .accepted
        case .saturated:
            return .saturated
        case .cancelled:
            return .cancelled
        }
    }

    /// Synchronous socket-command path. The mutation bus still owns capacity
    /// waiting on its serial admission queue; this caller waits for the
    /// admission result before acknowledging hook commands that discard replies.
    func enqueueReliablySynchronously(
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
        let result = TerminalMutationBus.shared.enqueueNotificationReliablySynchronously(
            tabId: workspaceID,
            surfaceId: surfaceID,
            title: title,
            subtitle: subtitle,
            body: body
        )
        switch result {
        case .accepted:
            return .accepted
        case .saturated:
            return .saturated
        case .cancelled:
            return .cancelled
        }
    }
}
