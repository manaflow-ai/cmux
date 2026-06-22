public import CmuxMobileRPC
public import Foundation
import Observation

/// Phone-side mirror of the Mac's notification feed.
///
/// Holds the recent notifications (newest-first value snapshots) streamed from
/// the connected Mac for the Notifications tab. Workspace unread indicators and
/// the app icon badge are reconciled through the existing Mac-backed workspace
/// read-state and notification badge events; this store only owns feed rows.
///
/// All mutation is replace-or-flip on a value array, so there is no Combine, no
/// `@Published`, and nothing that crosses a `List` boundary: the views read
/// derived values and pass each row an immutable preview.
@MainActor
@Observable
public final class MobileNotificationsStore {
    /// Recent notifications, newest-first. Capped to ``recentLimit`` on apply.
    public private(set) var notifications: [MobileNotificationPreview] = []

    /// How many recent notifications the feed keeps. Matches the Mac-side cap so
    /// a refetch (replace) and the live feed agree on the visible window.
    /// `nonisolated` so the static `normalizedNotifications` helper can read it
    /// without hopping to the main actor.
    public nonisolated static let recentLimit = 200

    /// Create a store seeded with `notifications` (sorted newest-first + capped).
    public init(notifications: [MobileNotificationPreview] = []) {
        self.notifications = Self.normalizedNotifications(notifications)
    }

    /// Replace the feed with a fresh snapshot from the Mac.
    ///
    /// Replace-with-recent-N matches the workspace-list refetch contract: the
    /// Mac's store is authoritative, so the latest snapshot wins outright. Items
    /// older than ``recentLimit`` drop off; pagination is future work.
    public func apply(_ snapshot: [MobileNotificationPreview]) {
        notifications = Self.normalizedNotifications(snapshot)
    }

    /// Optimistically flip one notification to read so its badge clears
    /// immediately on open. Reconciled by the next refetch from the Mac.
    public func markReadLocally(id: String) {
        guard let index = notifications.firstIndex(where: { $0.id == id }),
              !notifications[index].isRead else { return }
        notifications[index].isRead = true
    }

    /// Optimistically flip every notification for a workspace to read. Reconciled
    /// by the next refetch from the Mac.
    public func markReadLocally(forWorkspace workspaceID: String) {
        notifications = notifications.map { notification in
            guard notification.workspaceID == workspaceID, !notification.isRead else {
                return notification
            }
            var updated = notification
            updated.isRead = true
            return updated
        }
    }

    /// Sort newest-first and cap to the recent window. `nonisolated static` so
    /// `init` and `apply` agree on ordering and the cap without hopping actors.
    private nonisolated static func normalizedNotifications(
        _ input: [MobileNotificationPreview]
    ) -> [MobileNotificationPreview] {
        let sorted = input.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            // Stable tiebreak so equal timestamps keep a deterministic order.
            return lhs.id > rhs.id
        }
        return Array(sorted.prefix(recentLimit))
    }
}
