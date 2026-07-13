import Foundation
import CmuxGit

/// Stages the existing production executor boundary without reaching GitHub.
/// The scheduler, request joining, completion authority, and result projection
/// remain the same paths used by the live executor.
actor SidebarGitOwnerPerformanceExecutor: PullRequestRefreshExecuting {
    private struct FetchWaiter {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var fetchCount = 0
    private let suppressesFetchCountSignal: Bool
    private var fetchGateOrder: [UUID] = []
    private var fetchGatesByID: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var fetchWaitersByID: [UUID: FetchWaiter] = [:]

    init(suppressesFetchCountSignal: Bool = false) {
        self.suppressesFetchCountSignal = suppressesFetchCountSignal
    }

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
        if !suppressesFetchCountSignal {
            fetchCount += 1
            resumeSatisfiedFetchWaiters()
        }
        let didRelease = await waitForFetchRelease()
        guard didRelease, !Task.isCancelled else { return [:] }

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

    func waitForFetchCount(_ minimumCount: Int) async throws {
        guard fetchCount < minimumCount else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                fetchWaitersByID[waiterID] = FetchWaiter(
                    minimumCount: minimumCount,
                    continuation: continuation
                )
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelFetchWaiter(waiterID) }
        }
    }

    func releaseNextFetch() {
        while let gateID = fetchGateOrder.first {
            fetchGateOrder.removeFirst()
            guard let continuation = fetchGatesByID.removeValue(forKey: gateID) else {
                continue
            }
            continuation.resume(returning: true)
            return
        }
    }

    func cancelAllPending() {
        let gates = Array(fetchGatesByID.values)
        let waiters = Array(fetchWaitersByID.values)
        fetchGatesByID.removeAll()
        fetchGateOrder.removeAll()
        fetchWaitersByID.removeAll()
        for gate in gates { gate.resume(returning: false) }
        for waiter in waiters {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    var pendingFetchGateCount: Int { fetchGatesByID.count }
    var pendingFetchWaiterCount: Int { fetchWaitersByID.count }

    private func waitForFetchRelease() async -> Bool {
        let gateID = UUID()
        let didRelease = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                fetchGateOrder.append(gateID)
                fetchGatesByID[gateID] = continuation
            }
        } onCancel: {
            Task { await self.cancelFetchGate(gateID) }
        }
        return didRelease && !Task.isCancelled
    }

    private func cancelFetchGate(_ gateID: UUID) {
        guard let continuation = fetchGatesByID.removeValue(forKey: gateID) else { return }
        fetchGateOrder.removeAll { $0 == gateID }
        continuation.resume(returning: false)
    }

    private func cancelFetchWaiter(_ waiterID: UUID) {
        fetchWaitersByID.removeValue(forKey: waiterID)?
            .continuation.resume(throwing: CancellationError())
    }

    private func resumeSatisfiedFetchWaiters() {
        let readyIDs = fetchWaitersByID.compactMap { id, waiter in
            waiter.minimumCount <= fetchCount ? id : nil
        }
        for waiterID in readyIDs {
            fetchWaitersByID.removeValue(forKey: waiterID)?
                .continuation.resume(returning: ())
        }
    }
}
