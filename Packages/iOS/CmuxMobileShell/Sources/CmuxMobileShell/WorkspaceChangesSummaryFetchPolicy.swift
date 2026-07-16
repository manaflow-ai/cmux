internal import Foundation

/// Pure batching and client-side reuse policy for workspace summary RPCs.
struct WorkspaceChangesSummaryFetchPolicy: Sendable {
    let maximumBatchSize: Int
    let reuseWindow: TimeInterval

    init(maximumBatchSize: Int = 64, reuseWindow: TimeInterval = 15) {
        precondition(maximumBatchSize > 0)
        self.maximumBatchSize = maximumBatchSize
        self.reuseWindow = reuseWindow
    }

    func batches(
        workspaceIDs: [String],
        fetchedAtByWorkspaceID: [String: Date],
        now: Date,
        force: Bool
    ) -> [[String]] {
        var seen: Set<String> = []
        let eligible = workspaceIDs.filter { workspaceID in
            guard !workspaceID.isEmpty, seen.insert(workspaceID).inserted else {
                return false
            }
            guard !force, let fetchedAt = fetchedAtByWorkspaceID[workspaceID] else {
                return true
            }
            return now.timeIntervalSince(fetchedAt) >= reuseWindow
        }

        var result: [[String]] = []
        var start = 0
        while start < eligible.count {
            let end = min(start + maximumBatchSize, eligible.count)
            result.append(Array(eligible[start..<end]))
            start = end
        }
        return result
    }
}
