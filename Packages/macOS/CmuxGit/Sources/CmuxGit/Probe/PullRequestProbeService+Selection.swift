public import Foundation

extension PullRequestProbeService {
    /// Indexes pull requests by normalized head-branch name, keeping the
    /// preferred PR per branch and dropping non-candidates (unparseable state,
    /// invalid URL, stale merged).
    nonisolated static func pullRequestMapByNormalizedBranch(
        from pullRequests: [GitHubPullRequestProbeItem],
        now: Date = Date()
    ) -> [String: GitHubPullRequestProbeItem] {
        var pullRequestsByBranch: [String: GitHubPullRequestProbeItem] = [:]

        for pullRequest in pullRequests {
            guard let branch = GitMetadataService.normalizedBranchName(pullRequest.headRefName),
                  isBadgeCandidate(pullRequest, now: now) else {
                continue
            }

            if let currentBest = pullRequestsByBranch[branch] {
                pullRequestsByBranch[branch] = preferredPullRequest(
                    from: [currentBest, pullRequest],
                    now: now
                ) ?? currentBest
            } else {
                pullRequestsByBranch[branch] = pullRequest
            }
        }

        return pullRequestsByBranch
    }

    /// Picks the pull request a badge should show: open beats merged beats
    /// closed, then most recently updated, then highest number. Returns `nil`
    /// when no item is a valid badge candidate.
    public nonisolated static func preferredPullRequest(
        from pullRequests: [GitHubPullRequestProbeItem],
        now: Date = Date()
    ) -> GitHubPullRequestProbeItem? {
        func statusPriority(_ status: PullRequestStatus) -> Int {
            switch status {
            case .open:
                return 3
            case .merged:
                return 2
            case .closed:
                return 1
            }
        }

        func isPreferred(
            candidate: GitHubPullRequestProbeItem,
            over current: GitHubPullRequestProbeItem
        ) -> Bool {
            guard let candidateStatus = PullRequestStatus(githubState: candidate.state),
                  let currentStatus = PullRequestStatus(githubState: current.state) else {
                return false
            }

            let candidatePriority = statusPriority(candidateStatus)
            let currentPriority = statusPriority(currentStatus)
            if candidatePriority != currentPriority {
                return candidatePriority > currentPriority
            }

            let candidateUpdatedAt = candidate.updatedAt ?? ""
            let currentUpdatedAt = current.updatedAt ?? ""
            if candidateUpdatedAt != currentUpdatedAt {
                return candidateUpdatedAt > currentUpdatedAt
            }

            return candidate.number > current.number
        }

        var best: GitHubPullRequestProbeItem?
        for pullRequest in pullRequests {
            guard isBadgeCandidate(pullRequest, now: now) else {
                continue
            }
            guard let currentBest = best else {
                best = pullRequest
                continue
            }
            if isPreferred(candidate: pullRequest, over: currentBest) {
                best = pullRequest
            }
        }
        return best
    }

    /// Whether a PR can back a badge at all: parseable state, valid URL, and
    /// not a stale merged PR.
    nonisolated static func isBadgeCandidate(
        _ pullRequest: GitHubPullRequestProbeItem,
        now: Date
    ) -> Bool {
        guard PullRequestStatus(githubState: pullRequest.state) != nil,
              URL(string: pullRequest.url) != nil else {
            return false
        }
        return !isStaleMerged(pullRequest, now: now)
    }

    /// Whether a merged PR is older than ``mergedBadgeStaleAfter``.
    nonisolated static func isStaleMerged(
        _ pullRequest: GitHubPullRequestProbeItem,
        now: Date
    ) -> Bool {
        guard PullRequestStatus(githubState: pullRequest.state) == .merged,
              let mergedAt = githubTimestampDate(from: pullRequest.mergedAt) else {
            return false
        }
        return now.timeIntervalSince(mergedAt) > Self.mergedBadgeStaleAfter
    }

    /// Parses a GitHub ISO-8601 timestamp (with or without fractional seconds).
    nonisolated static func githubTimestampDate(from rawTimestamp: String?) -> Date? {
        let timestamp = rawTimestamp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !timestamp.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: timestamp) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp)
    }

    /// Decodes JSON `Data`, returning `nil` on any decode failure.
    nonisolated static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(T.self, from: data)
    }
}
