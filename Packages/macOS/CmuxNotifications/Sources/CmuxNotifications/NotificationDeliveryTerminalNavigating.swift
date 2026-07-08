public import Foundation

/// Routes terminal notification responses into the notification navigation
/// coordinator.
@MainActor
public protocol NotificationDeliveryTerminalNavigating: AnyObject {
    /// Opens the terminal notification target and marks `notificationId` read on
    /// success through the app-side open-routing seam.
    @discardableResult
    func open(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool

    /// Opens a stored terminal notification, preserving any app-side context
    /// that was not included in the delivered OS notification payload.
    @discardableResult
    func openNotification(id: UUID, fallbackTabId: UUID, fallbackSurfaceId: UUID?) -> Bool

    /// Performs a terminal notification click action.
    @discardableResult
    func performClickAction(_ action: NotificationNavClickAction) -> Bool

    /// Marks a terminal notification read.
    func markNotificationRead(id: UUID)
}
