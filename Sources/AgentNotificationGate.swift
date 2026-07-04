import CmuxControlSocket
import Foundation
import CmuxSettings

typealias AgentNotifyCategory = CmuxControlSocket.AgentNotifyCategory
typealias AgentTurnCompleteMode = CmuxControlSocket.AgentTurnCompleteMode
typealias AgentNotificationMeta = CmuxControlSocket.AgentNotificationMeta

/// Pure delivery decision for agent-tagged notifications. Kept free of any I/O
/// so it can be exhaustively unit-tested against the decision table.
nonisolated func agentNotificationShouldDeliver(
    category: AgentNotifyCategory,
    pending: Bool,
    permissionEnabled: Bool,
    turnMode: AgentTurnCompleteMode,
    idleEnabled: Bool
) -> Bool {
    category.shouldDeliver(
        pending: pending,
        permissionEnabled: permissionEnabled,
        turnMode: turnMode,
        idleEnabled: idleEnabled
    )
}

struct AgentNotificationSettingsGate: Sendable {
    private let settings: any SettingsReading
    private let notificationsSettings: NotificationsCatalogSection

    init(
        settings: any SettingsReading = UserDefaultsSettingsClient(defaults: .standard),
        notificationsSettings: NotificationsCatalogSection = NotificationsCatalogSection()
    ) {
        self.settings = settings
        self.notificationsSettings = notificationsSettings
    }

    func shouldDeliver(_ meta: AgentNotificationMeta?) -> Bool {
        guard let meta else { return true }
        let turnMode = AgentTurnCompleteMode(
            rawValue: settings.value(for: notificationsSettings.agentTurnComplete)
        ) ?? .whenIdle
        return agentNotificationShouldDeliver(
            category: meta.category,
            pending: meta.pending,
            permissionEnabled: settings.value(for: notificationsSettings.agentPermissionPrompt),
            turnMode: turnMode,
            idleEnabled: settings.value(for: notificationsSettings.agentIdleReminder)
        )
    }
}

extension TerminalController {
    private static let agentNotificationSettingsGate = AgentNotificationSettingsGate()

    func shouldDeliverAgentNotification(_ meta: AgentNotificationMeta?) -> Bool {
        Self.agentNotificationSettingsGate.shouldDeliver(meta)
    }
}
