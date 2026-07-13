import Foundation
import CmuxGit

/// Stages the existing production executor boundary without reaching GitHub.
/// The scheduler, request joining, completion authority, and result projection
/// remain the same paths used by the live executor.
actor SidebarGitOwnerPerformanceExecutor: PullRequestRefreshExecuting {
    private struct FetchWaiter {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var fetchCount = 0
    private var fetchContinuations: [CheckedContinuation<Void, Never>] = []
    private var fetchWaiters: [FetchWaiter] = []

    func resolveCandidateSeeds(
        _ seeds: [WorkspacePullRequestCandidateSeed]
    ) -> WorkspacePullRequestCandidateResolution {
        let candidates = seeds.map {
            WorkspacePullRequestCandidate(
                workspaceId: $0.workspaceId,
                panelId: $0.panelId,
                branch: $0.branch,
                repoSlugs: ["cmux/owner-proof"]
            )
        }
        return WorkspacePullRequestCandidateResolution(
            candidates: candidates,
            candidateBranchesByRepo: ["cmux/owner-proof": Set(candidates.map(\.branch))],
            repoDirectoriesBySlug: ["cmux/owner-proof": "/isolated/owner-proof"]
        )
    }

    func fetchRepoResults(
        candidateResolution: WorkspacePullRequestCandidateResolution,
        cacheBySlug: [String: WorkspacePullRequestRepoCacheEntry],
        now: Date,
        allowCachedResults: Bool
    ) async -> [String: WorkspacePullRequestRepoFetchResult] {
        fetchCount += 1
        resumeSatisfiedFetchWaiters()
        await withCheckedContinuation { fetchContinuations.append($0) }

        var items: [String: GitHubPullRequestProbeItem] = [:]
        for branch in candidateResolution.candidateBranchesByRepo["cmux/owner-proof"] ?? [] {
            items[branch] = GitHubPullRequestProbeItem(
                number: 1,
                state: "OPEN",
                url: "https://github.invalid/cmux/owner-proof/pull/1",
                updatedAt: "2026-07-12T00:00:00Z",
                mergedAt: nil,
                headRefName: branch,
                baseRefName: "main"
            )
        }
        let cacheEntry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: now,
            pullRequestsByBranch: items
        )
        return [
            "cmux/owner-proof": .success(
                cacheEntry,
                usedCache: false,
                transientBranches: []
            ),
        ]
    }

    func waitForFetchCount(_ minimumCount: Int) async {
        guard fetchCount < minimumCount else { return }
        await withCheckedContinuation {
            fetchWaiters.append(FetchWaiter(minimumCount: minimumCount, continuation: $0))
        }
    }

    func releaseNextFetch() {
        guard !fetchContinuations.isEmpty else { return }
        fetchContinuations.removeFirst().resume()
    }

    private func resumeSatisfiedFetchWaiters() {
        let ready = fetchWaiters.filter { $0.minimumCount <= fetchCount }
        fetchWaiters.removeAll { $0.minimumCount <= fetchCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
