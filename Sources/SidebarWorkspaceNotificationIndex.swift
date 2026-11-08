import Foundation

/// Immutable notification projection shared by all rows in one sidebar pass.
///
/// The parent groups and sorts the flat store snapshot once. Lazy rows perform
/// dictionary presence checks or a bounded merge of the requested workspace
/// buckets; they never rescan the full notification history.
@MainActor
struct SidebarWorkspaceNotificationIndex {
    static let contextMenuNotificationLimit = 50

    private let notificationsByWorkspaceId: [UUID: [TerminalNotification]]

    init(notifications: [TerminalNotification]) {
        var grouped: [UUID: [TerminalNotification]] = [:]
        grouped.reserveCapacity(min(notifications.count, 64))
        for notification in notifications {
            grouped[notification.tabId, default: []].append(notification)
        }
        for workspaceId in Array(grouped.keys) {
            guard let bucket = grouped[workspaceId] else { continue }
            grouped[workspaceId] = Array(
                bucket
                    .sorted(by: TerminalNotificationStore.notificationSortPrecedes)
                    .prefix(Self.contextMenuNotificationLimit)
            )
        }
        notificationsByWorkspaceId = grouped
    }

    func hasNotification(workspaceId: UUID) -> Bool {
        notificationsByWorkspaceId[workspaceId]?.isEmpty == false
    }

    func hasNotification(workspaceIds: [UUID]) -> Bool {
        workspaceIds.contains { hasNotification(workspaceId: $0) }
    }

    func contextMenuNotifications(workspaceIds: [UUID]) -> [TerminalNotification] {
        var seenWorkspaceIds = Set<UUID>()
        let activeWorkspaceIds = workspaceIds.filter { workspaceId in
            seenWorkspaceIds.insert(workspaceId).inserted
                && notificationsByWorkspaceId[workspaceId]?.isEmpty == false
        }
        guard !activeWorkspaceIds.isEmpty else { return [] }

        var offsetsByWorkspaceId: [UUID: Int] = [:]
        offsetsByWorkspaceId.reserveCapacity(activeWorkspaceIds.count)
        var result: [TerminalNotification] = []
        result.reserveCapacity(Self.contextMenuNotificationLimit)

        while result.count < Self.contextMenuNotificationLimit {
            var newestWorkspaceId: UUID?
            var newestNotification: TerminalNotification?
            for workspaceId in activeWorkspaceIds {
                let offset = offsetsByWorkspaceId[workspaceId, default: 0]
                guard let bucket = notificationsByWorkspaceId[workspaceId],
                      offset < bucket.count else {
                    continue
                }
                let candidate = bucket[offset]
                if newestNotification.map({
                    TerminalNotificationStore.notificationSortPrecedes(candidate, $0)
                }) ?? true {
                    newestWorkspaceId = workspaceId
                    newestNotification = candidate
                }
            }
            guard let newestWorkspaceId, let newestNotification else { break }
            result.append(newestNotification)
            offsetsByWorkspaceId[newestWorkspaceId, default: 0] += 1
        }

        return result
    }
}
