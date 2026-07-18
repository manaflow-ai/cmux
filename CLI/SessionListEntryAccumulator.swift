import Foundation

/// Retains the exact sorted prefix for a bounded `agents list` query without
/// keeping every matching session payload in memory.
struct SessionListEntryAccumulator {
    private static let deterministicStringKeys = [
        "session_id", "agent", "run_id", "workspace_id", "surface_id", "identity_source",
    ]

    private struct Entry {
        var updatedAt: TimeInterval
        var payload: [String: Any]
    }

    private let limit: Int
    private var retained: [Entry] = []
    private(set) var totalCount = 0

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
        if limit != Int.max { retained.reserveCapacity(min(limit, 1_024)) }
    }

    var retainedCount: Int { retained.count }

    var sortedPayloads: [[String: Any]] {
        retained.sorted(by: Self.isOrderedBefore).map(\.payload)
    }

    mutating func insert(updatedAt: TimeInterval, payload: [String: Any]) {
        totalCount += 1
        let entry = Entry(updatedAt: updatedAt, payload: payload)
        guard limit != Int.max else {
            retained.append(entry)
            return
        }
        guard retained.count == limit else {
            retained.append(entry)
            siftUp(from: retained.count - 1)
            return
        }
        guard let worst = retained.first, Self.isOrderedBefore(entry, worst) else { return }
        retained[0] = entry
        siftDown(from: 0)
    }

    private mutating func siftUp(from start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.isWorse(retained[child], than: retained[parent]) else { return }
            retained.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            guard left < retained.count else { return }
            let right = left + 1
            let worseChild = right < retained.count && Self.isWorse(retained[right], than: retained[left])
                ? right
                : left
            guard Self.isWorse(retained[worseChild], than: retained[parent]) else { return }
            retained.swapAt(parent, worseChild)
            parent = worseChild
        }
    }

    private static func isOrderedBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        for key in deterministicStringKeys {
            let lhsValue = stringValue(lhs.payload, key: key)
            let rhsValue = stringValue(rhs.payload, key: key)
            if lhsValue != rhsValue { return lhsValue < rhsValue }
        }
        let lhsPID = lhs.payload["pid"] as? Int ?? Int.min
        let rhsPID = rhs.payload["pid"] as? Int ?? Int.min
        if lhsPID != rhsPID { return lhsPID < rhsPID }
        let lhsStartedAt = lhs.payload["process_started_at"] as? TimeInterval ?? -TimeInterval.infinity
        let rhsStartedAt = rhs.payload["process_started_at"] as? TimeInterval ?? -TimeInterval.infinity
        return lhsStartedAt < rhsStartedAt
    }

    private static func isWorse(_ lhs: Entry, than rhs: Entry) -> Bool {
        isOrderedBefore(rhs, lhs)
    }

    private static func stringValue(_ payload: [String: Any], key: String) -> String {
        (payload[key] as? String) ?? ""
    }
}
