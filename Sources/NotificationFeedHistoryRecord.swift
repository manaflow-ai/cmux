import Foundation

/// One durable cmux notification in the cross-device chronological feed.
struct NotificationFeedHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var tabId: UUID
    var surfaceId: UUID?
    var panelId: UUID?
    let retargetsToLiveSurfaceOwner: Bool
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool

    init(notification: TerminalNotification) {
        id = notification.id
        tabId = notification.tabId
        surfaceId = notification.surfaceId
        panelId = notification.panelId
        retargetsToLiveSurfaceOwner = notification.retargetsToLiveSurfaceOwner
        title = notification.title
        subtitle = notification.subtitle
        body = notification.body
        createdAt = notification.createdAt
        isRead = notification.isRead
    }

    func matches(tabId targetTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard tabId == targetTabId else { return false }
        guard let targetSurfaceId else {
            return surfaceId == nil && panelId == nil
        }
        return surfaceId == targetSurfaceId || panelId == targetSurfaceId
    }
}
