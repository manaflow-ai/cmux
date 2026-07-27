public import Foundation

/// Read/mutate seam over the app-target `TerminalNotificationStore`, scoped to
/// what notification navigation needs: the ordered notification list (newest
/// first, as the store maintains it), the set of workspaces that carry an
/// unread indicator, the two manual/restored unread predicates the jump-flash
/// decision consults, and the `markRead(id:)` mutation that confirms an open.
///
/// All methods are synchronous because every navigation flow is one MainActor
/// turn that reads the store and then mutates it without an intervening
/// suspension, exactly like the legacy inline code. A missing store makes every
/// read empty/`false` and `markRead` a no-op (mirroring the legacy
/// `guard let notificationStore` / `notificationStore?` chains).
@MainActor
public protocol NotificationNavigationStoreReading: AnyObject {
    /// The store's notifications in display order (newest first), reduced to
    /// navigation snapshots. Mirrors iterating `notificationStore.notifications`.
    var orderedNotifications: [NotificationNavSnapshot] { get }

    /// The set of workspace ids that currently carry an unread indicator.
    /// Mirrors `notificationStore.workspaceUnreadIndicatorIds`.
    var workspaceUnreadIndicatorIds: Set<UUID> { get }

    /// Whether the workspace carries a manually-set unread indicator.
    func hasManualUnread(forTabId tabId: UUID) -> Bool

    /// Whether the workspace carries a session-restored unread indicator.
    func hasRestoredUnreadIndicator(forTabId tabId: UUID) -> Bool

    /// Marks the single notification read after a successful open.
    func markRead(id: UUID)
}
