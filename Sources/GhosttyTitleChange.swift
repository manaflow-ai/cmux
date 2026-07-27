import Foundation

/// Typed payload for `.ghosttyDidSetTitle` notifications.
struct GhosttyTitleChange: Equatable, Sendable {
    let tabId: UUID
    let surfaceId: UUID
    let title: String
    let sourceSurfaceIdentifier: ObjectIdentifier?

    init(tabId: UUID, surfaceId: UUID, title: String, sourceSurfaceIdentifier: ObjectIdentifier? = nil) {
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.title = title
        self.sourceSurfaceIdentifier = sourceSurfaceIdentifier
    }

    init?(notification: Notification) {
        guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
              let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
              let title = notification.userInfo?[GhosttyNotificationKey.title] as? String else {
            return nil
        }
        self.init(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            sourceSurfaceIdentifier: notification.userInfo?[GhosttyNotificationKey.sourceSurfaceIdentifier]
                as? ObjectIdentifier ?? (notification.object as AnyObject?).map(ObjectIdentifier.init)
        )
    }

    var userInfo: [String: Any] {
        var info: [String: Any] = [
            GhosttyNotificationKey.tabId: tabId,
            GhosttyNotificationKey.surfaceId: surfaceId,
            GhosttyNotificationKey.title: title,
        ]
        if let sourceSurfaceIdentifier {
            info[GhosttyNotificationKey.sourceSurfaceIdentifier] = sourceSurfaceIdentifier
        }
        return info
    }

    func matches(sourceSurface: AnyObject) -> Bool {
        sourceSurfaceIdentifier.map { $0 == ObjectIdentifier(sourceSurface) } ?? true
    }
}
