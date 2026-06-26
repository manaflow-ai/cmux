import Foundation

/// Typed payload for `.ghosttyDidFocusSurface` notifications.
struct GhosttyFocusSurfaceChange: Equatable, Sendable {
    let tabId: UUID
    let surfaceId: UUID
    let explicitFocusIntent: Bool

    init(tabId: UUID, surfaceId: UUID, explicitFocusIntent: Bool) {
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.explicitFocusIntent = explicitFocusIntent
    }

    init?(notification: Notification) {
        guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
              let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else {
            return nil
        }
        let explicitFocusIntent = notification.userInfo?[GhosttyNotificationKey.explicitFocusIntent] as? Bool ?? false
        self.init(tabId: tabId, surfaceId: surfaceId, explicitFocusIntent: explicitFocusIntent)
    }
}
