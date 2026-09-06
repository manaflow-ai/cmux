import Foundation

/// Applies independent bounds to the shared closed-item history.
nonisolated struct ClosedItemHistoryCapacityPolicy: Sendable {
    let totalCapacity: Int?
    let workspaceCapacity: Int?

    private nonisolated struct RecencyKey: Sendable {
        let recordIndex: Int
        let closedAt: Date
    }

    /// Creates independent total-history and workspace-history bounds.
    init(totalCapacity: Int?, workspaceCapacity: Int?) {
        self.totalCapacity = totalCapacity.map { max(1, $0) }
        self.workspaceCapacity = workspaceCapacity.map { max(1, $0) }
    }

    /// Returns records that survive both bounds while preserving recency order.
    func trimming(
        _ records: [ClosedItemHistoryRecord],
        preservingRecordAt protectedRecordIndex: Int? = nil
    ) -> [ClosedItemHistoryRecord] {
        var result = records
        var protectedRecordIndex = protectedRecordIndex.flatMap {
            records.indices.contains($0) ? $0 : nil
        }
        let previousCount = result.count
        trimTotalCapacity(
            in: &result,
            preservingRecordAt: &protectedRecordIndex
        )
        trimWorkspaceCapacity(
            in: &result,
            preservingRecordAt: protectedRecordIndex
        )
        if result.count != previousCount {
            // The eviction rules use closedAt as the recency source of truth.
            // Keep the retained array in that same order because menuSnapshot()
            // presents it by reversing the stored sequence. Async persisted
            // loads apply this policy on the persistence actor before the
            // result reaches the main actor.
            result = result.enumerated()
                .sorted { lhs, rhs in
                    if lhs.element.closedAt != rhs.element.closedAt {
                        return lhs.element.closedAt < rhs.element.closedAt
                    }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
        }
        return result
    }

    /// Reports whether an insertion may exceed either configured bound.
    func shouldTrim(
        afterInserting record: ClosedItemHistoryRecord,
        totalCount: Int
    ) -> Bool {
        if let totalCapacity, totalCount > totalCapacity {
            return true
        }
        guard workspaceCapacity != nil else { return false }
        if case .workspace = record.entry {
            return true
        }
        return false
    }

    /// Removes the oldest records until the total bound is satisfied.
    private func trimTotalCapacity(
        in records: inout [ClosedItemHistoryRecord],
        preservingRecordAt protectedRecordIndex: inout Int?
    ) {
        guard let totalCapacity, records.count > totalCapacity else { return }
        let retainedIndexes = retainedNewestRecordIndexes(
            in: records,
            capacity: totalCapacity,
            preservingRecordAt: protectedRecordIndex
        ) { _ in true }
        var retainedRecords: [ClosedItemHistoryRecord] = []
        retainedRecords.reserveCapacity(retainedIndexes.count)
        var retainedProtectedRecordIndex: Int?
        for (recordIndex, record) in records.enumerated() {
            guard retainedIndexes.contains(recordIndex) else { continue }
            if let protectedRecordIndex, recordIndex == protectedRecordIndex {
                retainedProtectedRecordIndex = retainedRecords.count
            }
            retainedRecords.append(record)
        }
        records = retainedRecords
        protectedRecordIndex = retainedProtectedRecordIndex
    }

    /// Removes the oldest workspace records until their sub-bound is satisfied.
    private func trimWorkspaceCapacity(
        in records: inout [ClosedItemHistoryRecord],
        preservingRecordAt protectedRecordIndex: Int?
    ) {
        guard let workspaceCapacity else { return }
        let workspaceCount = records.reduce(into: 0) { count, record in
            if case .workspace = record.entry {
                count += 1
            }
        }
        guard workspaceCount > workspaceCapacity else { return }

        let retainedWorkspaceIndexes = retainedNewestRecordIndexes(
            in: records,
            capacity: workspaceCapacity,
            preservingRecordAt: protectedRecordIndex
        ) { record in
            if case .workspace = record.entry {
                return true
            }
            return false
        }
        records = records.enumerated()
            .filter { index, record in
                guard case .workspace = record.entry else { return true }
                return retainedWorkspaceIndexes.contains(index)
            }
            .map(\.element)
    }

    /// Selects newest matching insertion positions with memory bounded by `capacity`.
    private func retainedNewestRecordIndexes(
        in records: [ClosedItemHistoryRecord],
        capacity: Int,
        preservingRecordAt protectedRecordIndex: Int?,
        matching predicate: (ClosedItemHistoryRecord) -> Bool
    ) -> Set<Int> {
        guard capacity > 0 else { return [] }

        let protectedRecordIndex = protectedRecordIndex.flatMap { recordIndex -> Int? in
            guard records.indices.contains(recordIndex),
                  predicate(records[recordIndex]) else {
                return nil
            }
            return recordIndex
        }
        let selectionCapacity = capacity - (protectedRecordIndex == nil ? 0 : 1)
        var heap: [RecencyKey] = []
        heap.reserveCapacity(selectionCapacity)

        for (recordIndex, record) in records.enumerated() {
            guard recordIndex != protectedRecordIndex, predicate(record) else { continue }
            insertIntoOldestFirstHeap(
                RecencyKey(
                    recordIndex: recordIndex,
                    closedAt: record.closedAt
                ),
                heap: &heap,
                capacity: selectionCapacity
            )
        }

        var retainedIndexes = Set<Int>(minimumCapacity: heap.count + (protectedRecordIndex == nil ? 0 : 1))
        if let protectedRecordIndex {
            retainedIndexes.insert(protectedRecordIndex)
        }
        retainedIndexes.formUnion(heap.lazy.map(\.recordIndex))
        return retainedIndexes
    }

    /// Keeps a newest-record candidate in a min-heap whose root is oldest.
    private func insertIntoOldestFirstHeap(
        _ key: RecencyKey,
        heap: inout [RecencyKey],
        capacity: Int
    ) {
        guard capacity > 0 else { return }
        if heap.count < capacity {
            heap.append(key)
            siftUpOldestFirstHeap(&heap)
            return
        }
        guard let oldest = heap.first, isOlder(oldest, than: key) else { return }
        heap[0] = key
        siftDownOldestFirstHeap(&heap)
    }

    /// Restores the oldest-first invariant after appending a candidate.
    private func siftUpOldestFirstHeap(_ heap: inout [RecencyKey]) {
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard isOlder(heap[child], than: heap[parent]) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    /// Restores the oldest-first invariant after replacing the heap root.
    private func siftDownOldestFirstHeap(_ heap: inout [RecencyKey]) {
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { return }
            var oldestChild = left
            let right = left + 1
            if right < heap.count, isOlder(heap[right], than: heap[left]) {
                oldestChild = right
            }
            guard isOlder(heap[oldestChild], than: heap[parent]) else { return }
            heap.swapAt(parent, oldestChild)
            parent = oldestChild
        }
    }

    /// Compares recency using close time, then stable insertion order.
    private func isOlder(_ lhs: RecencyKey, than rhs: RecencyKey) -> Bool {
        if lhs.closedAt != rhs.closedAt {
            return lhs.closedAt < rhs.closedAt
        }
        return lhs.recordIndex < rhs.recordIndex
    }
}
