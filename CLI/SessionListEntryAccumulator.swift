import Foundation

/// Retains the exact sorted prefix for a bounded `agents list` query without
/// keeping every matching session payload in memory.
struct SessionListEntryAccumulator {
    typealias Enrichment = (inout [String: Any]) -> Void
    typealias PayloadFactory = () -> [String: Any]

    struct SortValues {
        var sessionID: String?
        var agent: String?
        var runID: String?
        var workspaceID: String?
        var surfaceID: String?
        var identitySource: String?
        var pid: Int?
        var processStartedAt: TimeInterval?

        init(
            sessionID: String?,
            agent: String?,
            runID: String?,
            workspaceID: String?,
            surfaceID: String?,
            identitySource: String?,
            pid: Int?,
            processStartedAt: TimeInterval?
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.runID = runID
            self.workspaceID = workspaceID
            self.surfaceID = surfaceID
            self.identitySource = identitySource
            self.pid = pid
            self.processStartedAt = processStartedAt
        }

        init(payload: [String: Any]) {
            sessionID = payload["session_id"] as? String
            agent = payload["agent"] as? String
            runID = payload["run_id"] as? String
            workspaceID = payload["workspace_id"] as? String
            surfaceID = payload["surface_id"] as? String
            identitySource = payload["identity_source"] as? String
            pid = payload["pid"] as? Int
            processStartedAt = payload["process_started_at"] as? TimeInterval
        }

        static func isOrderedBefore(_ lhs: Self, _ rhs: Self) -> Bool {
            if let result = stringPrecedes(lhs.sessionID, rhs.sessionID) { return result }
            if let result = stringPrecedes(lhs.agent, rhs.agent) { return result }
            if let result = stringPrecedes(lhs.runID, rhs.runID) { return result }
            if let result = stringPrecedes(lhs.workspaceID, rhs.workspaceID) { return result }
            if let result = stringPrecedes(lhs.surfaceID, rhs.surfaceID) { return result }
            if let result = stringPrecedes(lhs.identitySource, rhs.identitySource) { return result }
            let lhsPID = lhs.pid ?? Int.min
            let rhsPID = rhs.pid ?? Int.min
            if lhsPID != rhsPID { return lhsPID < rhsPID }
            return (lhs.processStartedAt ?? -.infinity) < (rhs.processStartedAt ?? -.infinity)
        }

        private static func stringPrecedes(_ lhs: String?, _ rhs: String?) -> Bool? {
            let lhs = lhs ?? ""
            let rhs = rhs ?? ""
            return lhs == rhs ? nil : lhs < rhs
        }
    }

    private struct Entry {
        var updatedAt: TimeInterval
        var sortValues: SortValues
        var payloadFactory: PayloadFactory
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
        var payloads: [[String: Any]] = []
        payloads.reserveCapacity(retained.count)
        forEachSortedPayload { payloads.append($0) }
        return payloads
    }

    func forEachSortedPayload(
        _ visit: ([String: Any]) throws -> Void
    ) rethrows {
        for entry in retained.sorted(by: Self.isOrderedBefore) {
            try autoreleasepool {
                var payload: [String: Any]? = entry.payloadFactory()
                try visit(payload ?? [:])
                // Release Swift and Foundation enrichment objects before
                // constructing the next row. Unbounded `--all` output must
                // retain compact sources, not materialized dictionaries or
                // autoreleased JSON bridges from every prior row.
                payload = nil
            }
        }
    }

    mutating func insert(
        updatedAt: TimeInterval,
        payload: [String: Any],
        enrichment: Enrichment? = nil
    ) {
        insert(
            updatedAt: updatedAt,
            sortValues: SortValues(payload: payload),
            payloadFactory: {
                var result = payload
                enrichment?(&result)
                return result
            }
        )
    }

    mutating func insert(
        updatedAt: TimeInterval,
        sortValues: SortValues,
        payloadFactory: @escaping PayloadFactory
    ) {
        totalCount += 1
        let entry = Entry(
            updatedAt: updatedAt,
            sortValues: sortValues,
            payloadFactory: payloadFactory
        )
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
        return SortValues.isOrderedBefore(lhs.sortValues, rhs.sortValues)
    }

    private static func isWorse(_ lhs: Entry, than rhs: Entry) -> Bool {
        isOrderedBefore(rhs, lhs)
    }
}
