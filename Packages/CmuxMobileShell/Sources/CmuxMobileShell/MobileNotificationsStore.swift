public import CmuxMobileRPC
public import Foundation
import Observation

/// Phone-side mirror of the Mac's notification feed.
///
/// Holds the recent notifications (newest-first value snapshots) streamed from
/// the connected Mac and derives the unread model the UI renders: a total
/// unread count for the Notifications tab badge and a per-workspace unread
/// count for the workspace-row badges. It is the single source for the phone's
/// unread state, derived purely from the mirrored feed (it does not try to
/// replicate the Mac's desktop-only manual/panel/restored indicator sets).
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
    /// `nonisolated` so the file-scope `normalizedNotifications` helper can read
    /// it without hopping to the main actor.
    public nonisolated static let recentLimit = 200

    /// Create a store seeded with `notifications` (sorted newest-first + capped).
    public init(notifications: [MobileNotificationPreview] = []) {
        self.notifications = normalizedNotifications(notifications)
    }

    /// Total number of unread notifications. Drives the Notifications tab badge.
    public var unreadCount: Int {
        notifications.reduce(into: 0) { $0 += ($1.isRead ? 0 : 1) }
    }

    /// Unread notifications for one workspace. Drives the per-workspace badge.
    public func unreadCount(forWorkspace workspaceID: String) -> Int {
        notifications.reduce(into: 0) { partial, notification in
            if notification.workspaceID == workspaceID, !notification.isRead {
                partial += 1
            }
        }
    }

    /// A `[workspaceID: unreadCount]` map for all workspaces with unread
    /// notifications. Computed once in the list's parent so the badge value can
    /// be handed to each row as a plain `Int` (no store crosses the boundary).
    public func unreadCountsByWorkspace() -> [String: Int] {
        notifications.reduce(into: [String: Int]()) { partial, notification in
            guard !notification.isRead else { return }
            partial[notification.workspaceID, default: 0] += 1
        }
    }

    /// Replace the feed with a fresh snapshot from the Mac.
    ///
    /// Replace-with-recent-N matches the workspace-list refetch contract: the
    /// Mac's store is authoritative, so the latest snapshot wins outright. Items
    /// older than ``recentLimit`` drop off; pagination is future work.
    public func apply(_ snapshot: [MobileNotificationPreview]) {
        notifications = normalizedNotifications(snapshot)
    }

    /// Optimistically flip one notification to read so its badge clears
    /// immediately on open. Reconciled by the next refetch from the Mac.
    public func markReadLocally(id: String) {
        guard let index = notifications.firstIndex(where: { $0.id == id }),
              !notifications[index].isRead else { return }
        notifications[index].isRead = true
    }

    /// Optimistically flip every notification for a workspace to read (used when
    /// the workspace is opened from the feed or the list). Reconciled by refetch.
    public func markReadLocally(forWorkspace workspaceID: String) {
        var didChange = false
        notifications = notifications.map { notification in
            guard notification.workspaceID == workspaceID, !notification.isRead else {
                return notification
            }
            didChange = true
            var updated = notification
            updated.isRead = true
            return updated
        }
        _ = didChange
    }
}

/// Sort newest-first and cap to the recent window. File-scope so `init` and
/// `apply` agree on ordering and the cap.
private func normalizedNotifications(
    _ input: [MobileNotificationPreview]
) -> [MobileNotificationPreview] {
    let sorted = input.sorted { lhs, rhs in
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        // Stable tiebreak so equal timestamps keep a deterministic order.
        return lhs.id > rhs.id
    }
    return Array(sorted.prefix(MobileNotificationsStore.recentLimit))
}
