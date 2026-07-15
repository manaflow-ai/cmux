import CmuxRemoteSession
import Foundation

enum TerminalNotificationQueueErrorMessages {
    static var saturated: String {
        String(
            localized: "notification.queue.error.saturated",
            defaultValue: "ERROR: notification queue saturated; retry"
        )
    }
}

struct QueuedTerminalNotificationKey: Hashable, Sendable {
    let tabId: UUID
    let surfaceId: UUID?
}

struct QueuedTerminalNotification: Sendable {
    let id: UUID
    let acceptedAt: Date
    let key: QueuedTerminalNotificationKey
    let title: String
    let subtitle: String
    let body: String
}

struct TerminalNotificationAdmissionToken: Sendable {
    let id: UUID
}

struct ReliableTerminalNotificationAdmission {
    let id: UUID
    let acceptedAt: Date
    var key: QueuedTerminalNotificationKey
    let notificationGeneration: UInt64
}

struct TerminalNotificationReplacementRoute {
    let toTabId: UUID
    let panelIdMap: [UUID: UUID]
}

enum TerminalSocketMutation {
    case deliverNotification(QueuedTerminalNotification)
    case clearAllNotifications(through: UInt64)
    case clearNotificationsForTab(UUID, through: UInt64)
    case clearNotificationsForSurface(UUID, UUID, through: UInt64)
    case perform(@MainActor () -> Void)
}

struct TerminalSocketMutationEntry {
    let sequence: UInt64
    let mutation: TerminalSocketMutation
    let notificationGeneration: UInt64?
    let performReplaceKey: TerminalMutationReplaceKey?
}
