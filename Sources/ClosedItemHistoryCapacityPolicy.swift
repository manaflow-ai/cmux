import Foundation

/// Applies independent bounds to the shared closed-item history.
struct ClosedItemHistoryCapacityPolicy {
    let totalCapacity: Int?
    let workspaceCapacity: Int?

    init(totalCapacity: Int?, workspaceCapacity: Int?) {
        self.totalCapacity = totalCapacity.map { max(1, $0) }
        self.workspaceCapacity = workspaceCapacity.map { max(1, $0) }
    }

    func trimming(
        _ records: [ClosedItemHistoryRecord],
        preserving protectedRecordId: UUID? = nil
    ) -> [ClosedItemHistoryRecord] {
        var result = records
        trimTotalCapacity(in: &result, preserving: protectedRecordId)
        trimWorkspaceCapacity(in: &result, preserving: protectedRecordId)
        if result.count != records.count {
            // The eviction rules use closedAt as the recency source of truth.
            // Keep the retained array in that same order because menuSnapshot()
            // presents it by reversing the stored sequence.
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

    private func trimTotalCapacity(
        in records: inout [ClosedItemHistoryRecord],
        preserving protectedRecordId: UUID?
    ) {
        guard let totalCapacity, records.count > totalCapacity else { return }
        let overflow = records.count - totalCapacity
        let removalIds = Set(records.enumerated()
            .filter { $0.element.id != protectedRecordId }
            .sorted { lhs, rhs in
                if lhs.element.closedAt != rhs.element.closedAt {
                    return lhs.element.closedAt < rhs.element.closedAt
                }
                return lhs.offset < rhs.offset
            }
            .prefix(overflow)
            .map(\.element.id))
        records.removeAll { removalIds.contains($0.id) }
    }

    private func trimWorkspaceCapacity(
        in records: inout [ClosedItemHistoryRecord],
        preserving protectedRecordId: UUID?
    ) {
        guard let workspaceCapacity else { return }
        let workspaceRecords = records.enumerated().filter { _, record in
            if case .workspace = record.entry {
                return true
            }
            return false
        }
        let overflow = workspaceRecords.count - workspaceCapacity
        guard overflow > 0 else { return }

        let removalIds = Set(workspaceRecords
            .filter { $0.element.id != protectedRecordId }
            .sorted { lhs, rhs in
                if lhs.element.closedAt != rhs.element.closedAt {
                    return lhs.element.closedAt < rhs.element.closedAt
                }
                return lhs.offset < rhs.offset
            }
            .prefix(overflow)
            .map(\.element.id))
        records.removeAll { removalIds.contains($0.id) }
    }
}
