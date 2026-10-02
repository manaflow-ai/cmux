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
        let removalIds = Set(records.lazy
            .filter { $0.id != protectedRecordId }
            .prefix(overflow)
            .map(\.id))
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
