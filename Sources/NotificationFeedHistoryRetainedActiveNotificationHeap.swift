import Foundation

struct NotificationFeedHistoryRetainedActiveNotificationHeap: Sendable {
    let limit: Int
    private var storage: [TerminalNotification] = []

    init(limit: Int) {
        self.limit = limit
        storage.reserveCapacity(limit)
    }

    mutating func insert(_ notification: TerminalNotification) {
        guard limit > 0 else { return }
        guard storage.count >= limit else {
            storage.append(notification)
            siftUp(from: storage.count - 1)
            return
        }
        guard let oldest = storage.first,
              notificationFeedHistoryActiveNotificationPrecedes(notification, oldest) else {
            return
        }
        storage[0] = notification
        siftDown(from: 0)
    }

    func sortedNewestFirst() -> [TerminalNotification] {
        storage.sorted(by: notificationFeedHistoryActiveNotificationPrecedes)
    }

    private mutating func siftUp(from startIndex: Int) {
        var child = startIndex
        while child > 0 {
            let parent = (child - 1) / 2
            guard notificationFeedHistoryActiveNotificationIsOlder(
                storage[child],
                than: storage[parent]
            ) else { return }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from startIndex: Int) {
        var parent = startIndex
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var candidate = parent
            if left < storage.count,
               notificationFeedHistoryActiveNotificationIsOlder(storage[left], than: storage[candidate]) {
                candidate = left
            }
            if right < storage.count,
               notificationFeedHistoryActiveNotificationIsOlder(storage[right], than: storage[candidate]) {
                candidate = right
            }
            guard candidate != parent else { return }
            storage.swapAt(parent, candidate)
            parent = candidate
        }
    }
}

nonisolated func notificationFeedHistoryActiveNotificationPrecedes(
    _ lhs: TerminalNotification,
    _ rhs: TerminalNotification
) -> Bool {
    if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt > rhs.createdAt
    }
    return lhs.id.uuidString > rhs.id.uuidString
}

nonisolated private func notificationFeedHistoryActiveNotificationIsOlder(
    _ lhs: TerminalNotification,
    than rhs: TerminalNotification
) -> Bool {
    notificationFeedHistoryActiveNotificationPrecedes(rhs, lhs)
}
