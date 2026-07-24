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
        plan(
            workspaceIDs: workspaceIDs,
            fetchedAtByWorkspaceID: fetchedAtByWorkspaceID,
            now: now,
            force: force
        ).batches
    }

    func plan(
        workspaceIDs: [String],
        fetchedAtByWorkspaceID: [String: Date],
        now: Date,
        force: Bool
    ) -> WorkspaceChangesSummaryFetchPlan {
        var seen: Set<String> = []
        var freshUntilByWorkspaceID: [String: Date] = [:]
        let eligible = workspaceIDs.filter { workspaceID in
            guard !workspaceID.isEmpty, seen.insert(workspaceID).inserted else {
                return false
            }
            guard !force, let fetchedAt = fetchedAtByWorkspaceID[workspaceID] else {
                return true
            }
            let expiresAt = fetchedAt.addingTimeInterval(reuseWindow)
            guard now < expiresAt else { return true }
            freshUntilByWorkspaceID[workspaceID] = expiresAt
            return false
        }

        var result: [[String]] = []
        var start = 0
        while start < eligible.count {
            let end = min(start + maximumBatchSize, eligible.count)
            result.append(Array(eligible[start..<end]))
            start = end
        }
        return WorkspaceChangesSummaryFetchPlan(
            batches: result,
            freshUntilByWorkspaceID: freshUntilByWorkspaceID
        )
    }
}
