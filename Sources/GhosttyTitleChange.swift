import CmuxTerminal
import Foundation

/// Typed payload for `.ghosttyDidSetTitle` notifications.
struct GhosttyTitleChange: Equatable, Sendable {
    let tabId: UUID
    let surfaceId: UUID
    let title: String

    init(tabId: UUID, surfaceId: UUID, title: String) {
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.title = title
    }

    init?(notification: Notification) {
        guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
              let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
              let title = notification.userInfo?[GhosttyNotificationKey.title] as? String else {
            return nil
        }
        self.init(tabId: tabId, surfaceId: surfaceId, title: title)
    }

    var userInfo: [String: Any] {
        [
            GhosttyNotificationKey.tabId: tabId,
            GhosttyNotificationKey.surfaceId: surfaceId,
            GhosttyNotificationKey.title: title,
        ]
    }
}
