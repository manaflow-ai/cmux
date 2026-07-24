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

    private func trimTotalCapacity(
        in records: inout [ClosedItemHistoryRecord],
        preserving protectedRecordId: UUID?
    ) {
        guard let totalCapacity else { return }
        while records.count > totalCapacity {
            let removalIndex = records.firstIndex { $0.id != protectedRecordId } ?? records.startIndex
            records.remove(at: removalIndex)
        }
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

        let removalIndexes = workspaceRecords
            .filter { $0.element.id != protectedRecordId }
            .sorted { lhs, rhs in
                if lhs.element.closedAt != rhs.element.closedAt {
                    return lhs.element.closedAt < rhs.element.closedAt
                }
                return lhs.offset < rhs.offset
            }
            .prefix(overflow)
            .map(\.offset)
            .sorted(by: >)

        for index in removalIndexes {
            records.remove(at: index)
        }
    }
}
