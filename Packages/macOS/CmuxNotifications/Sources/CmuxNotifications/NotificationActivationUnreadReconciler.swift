public import Foundation

/// Owns the activation-driven unread-reconciliation *decision* lifted verbatim
/// from `AppDelegate.applicationDidBecomeActive(_:)`.
///
/// After the app side has run `notificationStore.handleApplicationDidBecomeActive()`
/// and resolved the active tab/surface, the legacy body decided: if the active
/// tab/surface has an unread notification, flash the focused pane when the tab
/// exists and the notification requires a pane flash, then mark the active
/// tab/surface read. The store reads/mutation go through
/// ``NotificationActivationUnreadHosting`` and the pane-flash effect through
/// ``NotificationActivationFlashing``; the live `TerminalNotificationStore`,
/// `TabManager`, and `Workspace` stay app-side behind those seams so this
/// package carries no AppKit.
///
/// A Coordinator (CONVENTIONS §2): it sequences a flow and owns no I/O.
/// `@MainActor` because the activation path is a MainActor UI path and both
/// seams it drives are `@MainActor`.
@MainActor
public final class NotificationActivationUnreadReconciler {
    private let store: any NotificationActivationUnreadHosting
    private let flashing: any NotificationActivationFlashing

    public init(
        store: any NotificationActivationUnreadHosting,
        flashing: any NotificationActivationFlashing
    ) {
        self.store = store
        self.flashing = flashing
    }

    /// Reconciles the active tab/surface's unread state on app activation.
    /// Mirrors the unread block in `AppDelegate.applicationDidBecomeActive(_:)`:
    /// bail when the active tab/surface is not unread; otherwise flash the
    /// focused pane when the tab exists and a pane-flash notification is unread,
    /// then mark the active tab/surface read.
    public func reconcile(activeTabId: UUID, surfaceId: UUID?) {
        guard store.hasUnreadNotification(forTabId: activeTabId, surfaceId: surfaceId) else { return }

        if let surfaceId,
           flashing.hasActiveTab(tabId: activeTabId),
           store.hasUnreadNotificationRequiringPaneFlash(forTabId: activeTabId, surfaceId: surfaceId) {
            flashing.triggerPaneFlash(tabId: activeTabId, surfaceId: surfaceId)
        }
        store.markRead(forTabId: activeTabId, surfaceId: surfaceId)
    }
}
