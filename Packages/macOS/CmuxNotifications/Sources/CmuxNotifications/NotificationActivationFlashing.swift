public import Foundation

/// The pane-flash effect seam driven by
/// ``NotificationActivationUnreadReconciler``.
///
/// The legacy `AppDelegate.applicationDidBecomeActive(_:)` unread block resolved
/// the active tab (`tabManager.tabs.first(where: { $0.id == tabId })`) and, when
/// the flash decision passed, played the focused-pane attention flash
/// (`tab.triggerNotificationFocusFlash(panelId: surfaceId, requiresSplit: false,
/// shouldFocus: false)`). Both touch the live `TabManager`/`Workspace`, which
/// stay app-side, so the reconciler reaches them through this seam.
///
/// ``hasActiveTab(tabId:)`` mirrors the `tab != nil` half of the legacy
/// `if let tab = tabManager.tabs.first(...)` guard, evaluated before the store's
/// pane-flash predicate so the short-circuit order is preserved.
/// ``triggerPaneFlash(tabId:surfaceId:)`` resolves the same tab and forwards
/// `Workspace.triggerNotificationFocusFlash`; it is a no-op when the tab is
/// absent, matching the legacy optional-chain.
@MainActor
public protocol NotificationActivationFlashing: AnyObject {
    /// Whether the active tab manager currently owns a tab with `tabId` (legacy
    /// `tabManager.tabs.first(where: { $0.id == tabId }) != nil`).
    func hasActiveTab(tabId: UUID) -> Bool

    /// Plays the focused-pane attention flash on `tabId`'s tab for `surfaceId`
    /// (legacy `tab.triggerNotificationFocusFlash(panelId: surfaceId,
    /// requiresSplit: false, shouldFocus: false)`). A no-op when the tab is
    /// absent.
    func triggerPaneFlash(tabId: UUID, surfaceId: UUID)
}
