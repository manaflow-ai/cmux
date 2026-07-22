import CmuxRemoteSession
import Dispatch
import Foundation

extension ReliableTerminalNotificationEnqueueResult {
    static let saturatedSocketResponse = "ERROR: notification queue saturated; retry"
}

struct QueuedTerminalNotificationKey: Hashable, Sendable {
    let tabId: UUID
    let surfaceId: UUID?
}

struct QueuedTerminalNotification: Sendable {
    let id: UUID
    let acceptedAt: Date
    let key: QueuedTerminalNotificationKey
    let allowWorkspaceFallbackForValidatedSurface: Bool
    let title: String
    let subtitle: String
    let body: String
    let contentByteCount: Int
}

struct QueuedTerminalNotificationPayload: Sendable {
    let title: String
    let subtitle: String
    let body: String
    let contentByteCount: Int
}

extension QueuedTerminalNotificationPayload {
    nonisolated init(normalizingTitle title: String, subtitle: String, body: String) {
        let normalized = TerminalNotificationStore.normalizedNotificationText(
            title: title,
            subtitle: subtitle,
            body: body
        )
        self.title = normalized.title
        self.subtitle = normalized.subtitle
        self.body = normalized.body
        contentByteCount = normalized.title.utf8.count
            + normalized.subtitle.utf8.count
            + normalized.body.utf8.count
    }
}

struct TerminalNotificationAdmissionToken: Sendable {
    let id: UUID
}

struct ReliableTerminalNotificationAdmission {
    let id: UUID
    let acceptedAt: Date
    var key: QueuedTerminalNotificationKey
    let allowWorkspaceFallbackForValidatedSurface: Bool
    let payload: QueuedTerminalNotificationPayload
    let notificationGeneration: UInt64
    let deadline: DispatchTime
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
