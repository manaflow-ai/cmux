internal import Foundation

/// Pure batching and client-side reuse policy for workspace summary RPCs.
struct WorkspaceChangesSummaryFetchPolicy: Sendable {
    let maximumBatchSize: Int
    let reuseWindow: TimeInterval
    let minimumTrailingRefreshDelay: TimeInterval

    init(
        maximumBatchSize: Int = 64,
        reuseWindow: TimeInterval = 15,
        minimumTrailingRefreshDelay: TimeInterval = 5
    ) {
        precondition(maximumBatchSize > 0)
        precondition(minimumTrailingRefreshDelay > 0)
        self.maximumBatchSize = maximumBatchSize
        self.reuseWindow = reuseWindow
        self.minimumTrailingRefreshDelay = minimumTrailingRefreshDelay
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

    func freshUntilAfterSuccessfulFetch(
        workspaceIDs: [String],
        fetchedAt: Date
    ) -> [String: Date] {
        let expiry = fetchedAt.addingTimeInterval(reuseWindow)
        return workspaceIDs.reduce(into: [:]) { expiries, workspaceID in
            guard !workspaceID.isEmpty else { return }
            expiries[workspaceID] = expiry
        }
    }

    func trailingRefreshDelay(deadline: Date, now: Date) -> TimeInterval {
        max(minimumTrailingRefreshDelay, deadline.timeIntervalSince(now))
    }
}
