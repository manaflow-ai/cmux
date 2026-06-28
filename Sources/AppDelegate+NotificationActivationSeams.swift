import AppKit
import CmuxNotifications
import Foundation

/// App-side adapter that lets the `CmuxNotifications` activation-unread seams
/// reach `AppDelegate` WITHOUT forming a retain cycle, mirroring
/// ``NotificationOpenRoutingSeamAdapter`` exactly.
/// ``NotificationActivationUnreadReconciler`` strong-refs this adapter; the
/// adapter holds a `weak var owner: AppDelegate?` and conforms to both seams by
/// forwarding to the live `notificationStore` / `tabManager`, so the graph has
/// no strong path back to `AppDelegate`.
///
/// When the owner and its late-bound `notificationStore`/`tabManager` are alive
/// (production) every method is byte-identical to the old inline
/// `applicationDidBecomeActive` body; when any has deallocated each degrades to
/// the same `false`/no-op the legacy `guard let notificationStore`/`guard let
/// tabManager` gates produced. Legal per CONVENTIONS §6: the live
/// `TerminalNotificationStore`, `TabManager`, and `Workspace` stay app-side
/// while the unread-reconciliation decision lives in the package.
@MainActor
final class NotificationActivationSeamAdapter:
    NotificationActivationUnreadHosting,
    NotificationActivationFlashing
{
    weak var owner: AppDelegate?

    init(owner: AppDelegate) {
        self.owner = owner
    }

    // MARK: NotificationActivationUnreadHosting

    func hasUnreadNotification(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        owner?.notificationStore?.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) ?? false
    }

    func hasUnreadNotificationRequiringPaneFlash(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        owner?.notificationStore?.hasUnreadNotificationRequiringPaneFlash(forTabId: tabId, surfaceId: surfaceId) ?? false
    }

    func markRead(forTabId tabId: UUID, surfaceId: UUID?) {
        owner?.notificationStore?.markRead(forTabId: tabId, surfaceId: surfaceId)
    }

    // MARK: NotificationActivationFlashing

    func hasActiveTab(tabId: UUID) -> Bool {
        owner?.tabManager?.tabs.contains(where: { $0.id == tabId }) ?? false
    }

    func triggerPaneFlash(tabId: UUID, surfaceId: UUID) {
        owner?.tabManager?.tabs.first(where: { $0.id == tabId })?
            .triggerNotificationFocusFlash(panelId: surfaceId, requiresSplit: false, shouldFocus: false)
    }
}
