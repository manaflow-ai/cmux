public import Foundation

/// Routes terminal notification responses into the notification navigation
/// coordinator.
@MainActor
public protocol NotificationDeliveryTerminalNavigating: AnyObject {
    /// Opens the terminal notification target and marks `notificationId` read on
    /// success through the app-side open-routing seam.
    @discardableResult
    func open(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool

    /// Opens the terminal notification target while preserving an optional
    /// originating-window anchor from an OS banner response. The default
    /// implementation preserves compatibility for navigators that do not need
    /// window-aware routing.
    @discardableResult
    func open(
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?,
        preferredWindowId: UUID?
    ) -> Bool

    /// Opens a stored terminal notification, preserving any app-side context
    /// that was not included in the delivered OS notification payload. The
    /// fallback window id anchors a banner click to its originating window;
    /// fallback provenance controls whether a missing stored notification may
    /// follow its surface into another workspace.
    @discardableResult
    func openNotification(
        id: UUID,
        fallbackTabId: UUID,
        fallbackSurfaceId: UUID?,
        fallbackWindowId: UUID?,
        fallbackRetargetsToLiveSurfaceOwner: Bool
    ) -> Bool

    /// Performs a terminal notification click action.
    @discardableResult
    func performClickAction(_ action: NotificationNavClickAction) -> Bool

    /// Marks a terminal notification read.
    func markNotificationRead(id: UUID)
}

public extension NotificationDeliveryTerminalNavigating {
    @discardableResult
    func open(
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?,
        preferredWindowId: UUID?
    ) -> Bool {
        open(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
    }
}
