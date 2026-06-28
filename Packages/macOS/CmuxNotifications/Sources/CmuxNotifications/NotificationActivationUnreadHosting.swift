public import Foundation

/// The store-read seam ``NotificationActivationUnreadReconciler`` consults to
/// decide what to do with the active tab/surface when the app becomes active.
///
/// Every method mirrors one read or mutation the legacy
/// `AppDelegate.applicationDidBecomeActive(_:)` unread block made on
/// `notificationStore` (a `TerminalNotificationStore`):
/// `hasUnreadNotification(forTabId:surfaceId:)`,
/// `hasUnreadNotificationRequiringPaneFlash(forTabId:surfaceId:)`, and
/// `markRead(forTabId:surfaceId:)`. The store itself stays app-side; the
/// reconciler reaches it through this seam so the package carries no
/// `TerminalNotificationStore` dependency. Keyed by tab id plus an optional
/// surface id exactly as the store APIs are.
///
/// The app target's adapter forwards each method to its weakly-held
/// `notificationStore`, degrading to `false`/no-op when the store has
/// deallocated, matching the legacy `guard let notificationStore` entry gate
/// that returned early when the store was absent.
@MainActor
public protocol NotificationActivationUnreadHosting: AnyObject {
    /// Whether the active tab/surface has an unread notification (legacy
    /// `notificationStore.hasUnreadNotification(forTabId:surfaceId:)`).
    func hasUnreadNotification(forTabId tabId: UUID, surfaceId: UUID?) -> Bool

    /// Whether the active tab/surface has an unread notification that requires a
    /// focused-pane flash (legacy
    /// `notificationStore.hasUnreadNotificationRequiringPaneFlash(forTabId:surfaceId:)`).
    func hasUnreadNotificationRequiringPaneFlash(forTabId tabId: UUID, surfaceId: UUID?) -> Bool

    /// Marks the active tab/surface read (legacy
    /// `notificationStore.markRead(forTabId:surfaceId:)`).
    func markRead(forTabId tabId: UUID, surfaceId: UUID?)
}
