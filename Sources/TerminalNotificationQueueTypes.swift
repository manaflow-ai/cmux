import CmuxRemoteSession
import Foundation

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

enum TerminalSocketMutation {
    case deliverNotification(QueuedTerminalNotification)
    case clearAllNotifications
    case clearNotificationsForTab(UUID)
    case clearNotificationsForSurface(UUID, UUID)
    case perform(@MainActor () -> Void)
}

struct TerminalSocketMutationEntry {
    let sequence: UInt64
    let mutation: TerminalSocketMutation
    let notificationGeneration: UInt64?
    let performReplaceKey: TerminalMutationReplaceKey?
}
