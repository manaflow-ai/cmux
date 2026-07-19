import CmuxFoundation
import Foundation

/// Retains the exact sorted prefix for a bounded `agents list` query without
/// keeping every matching session payload in memory.
struct SessionListEntryAccumulator {
    typealias Enrichment = (inout [String: Any]) -> Void
    typealias PayloadFactory = () -> [String: Any]
    typealias SortValues = CmuxAgentSessionRegistry.HookListSortValues

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

    /// Accounts for matches proven by the registry count query whose payloads
    /// were intentionally not decoded because they cannot enter this top K.
    mutating func addUnmaterializedMatches(_ count: Int) {
        precondition(count >= 0)
        let sum = totalCount.addingReportingOverflow(count)
        totalCount = sum.overflow ? Int.max : sum.partialValue
    }

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
        CmuxAgentSessionRegistry.HookListOrderKey.isOrderedBefore(
            .init(updatedAt: lhs.updatedAt, sortValues: lhs.sortValues),
            .init(updatedAt: rhs.updatedAt, sortValues: rhs.sortValues)
        )
    }

    private static func isWorse(_ lhs: Entry, than rhs: Entry) -> Bool {
        isOrderedBefore(rhs, lhs)
    }
}

private extension CmuxAgentSessionRegistry.HookListSortValues {
    init(payload: [String: Any]) {
        self.init(
            sessionID: payload["session_id"] as? String,
            agent: payload["agent"] as? String,
            runID: payload["run_id"] as? String,
            workspaceID: payload["workspace_id"] as? String,
            surfaceID: payload["surface_id"] as? String,
            identitySource: payload["identity_source"] as? String,
            pid: payload["pid"] as? Int,
            processStartedAt: payload["process_started_at"] as? TimeInterval
        )
    }
}
