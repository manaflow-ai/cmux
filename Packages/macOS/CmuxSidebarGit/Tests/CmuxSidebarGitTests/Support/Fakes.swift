import Foundation
import CmuxGit
import CmuxFoundation
@testable import CmuxSidebarGit

/// A reader returning canned metadata, with an optional gate the test holds
/// closed to control exactly when a snapshot probe completes.
actor GatedMetadataReader: WorkspaceGitMetadataReading {
    private struct ProbeWaiter {
        let minimumCount: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let metadata: GitWorkspaceMetadata
    private let gated: Bool
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var probeWaitersByID: [UUID: ProbeWaiter] = [:]
    private var isOpen = false
    private(set) var probedDirectories: [String] = []
    private(set) var probedSnapshotRequests: [GitTrackedChangesSnapshotRequest?] = []

    var probedTrackedPathEventGenerations: [GitTrackedPathEventGeneration?] {
        probedSnapshotRequests.map { request in
            switch request {
            case .fallbackRound:
                nil
            case .watcherEvent(_, let eventID):
                eventID
            case nil:
                nil
            }
        }
    }

    var probedFallbackRoundIDs: [GitFallbackRoundID] {
        probedSnapshotRequests.compactMap { request in
            guard case .fallbackRound(let id, _) = request else { return nil }
            return id
        }
    }

    init(metadata: GitWorkspaceMetadata, gated: Bool = false) {
        self.metadata = metadata
        self.gated = gated
        self.isOpen = !gated
    }

    func openGate() {
        isOpen = true
        while !gateWaiters.isEmpty {
            gateWaiters.removeFirst().resume()
        }
    }

    nonisolated func waitForTrackedPathEventGenerationProbe(
        count minimumCount: Int = 1,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        await waitForProbeArrival(count: minimumCount, timeout: timeout)
    }

    nonisolated func waitForProbe(
        count minimumCount: Int = 1,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        await waitForProbeArrival(count: minimumCount, timeout: timeout)
    }

    private nonisolated func waitForProbeArrival(
        count minimumCount: Int,
        timeout: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForProbeArrival(count: minimumCount)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return false
                }
            }
            let didArrive = await group.next() ?? false
            group.cancelAll()
            return didArrive
        }
    }

    private func waitForProbeArrival(count minimumCount: Int) async -> Bool {
        if probedDirectories.count >= minimumCount {
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                probeWaitersByID[waiterID] = ProbeWaiter(
                    minimumCount: minimumCount,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelProbeWaiter(waiterID)
            }
        }
    }

    private func cancelProbeWaiter(_ waiterID: UUID) {
        probeWaitersByID.removeValue(forKey: waiterID)?.continuation.resume(returning: false)
    }

    private func resumeSatisfiedProbeWaiters() {
        let probeCount = probedDirectories.count
        let satisfiedWaiterIDs = probeWaitersByID.compactMap { id, waiter in
            waiter.minimumCount <= probeCount ? id : nil
        }
        for waiterID in satisfiedWaiterIDs {
            probeWaitersByID.removeValue(forKey: waiterID)?.continuation.resume(returning: true)
        }
    }

    func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata {
        await workspaceMetadata(for: directory, snapshotRequest: nil)
    }

    func workspaceMetadata(
        for directory: String,
        snapshotRequest: GitTrackedChangesSnapshotRequest?
    ) async -> GitWorkspaceMetadata {
        probedDirectories.append(directory)
        probedSnapshotRequests.append(snapshotRequest)
        resumeSatisfiedProbeWaiters()
        if !isOpen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isOpen {
                    continuation.resume()
                } else {
                    gateWaiters.append(continuation)
                }
            }
        }
        return metadata
    }
}

/// Records every call the git metadata service makes into the PR seam.
@MainActor
final class RecordingPullRequestProbing: PullRequestProbing {
    private struct SourceIdentity: Equatable {
        let directory: String
        let branch: String
    }

    private(set) var scheduledRefreshes: [(workspaceId: UUID, panelId: UUID, reason: String)] = []
    private(set) var clearedTrackingKeys: [(workspaceId: UUID, panelId: UUID)] = []
    private(set) var clearedTrackingWorkspaceIds: [UUID] = []
    var trackedPanelIdsByWorkspace: [UUID: Set<UUID>] = [:]
    private var sourceByKey: [WorkspaceGitProbeKey: SourceIdentity] = [:]
    private(set) var resetCount = 0

    func attach(host: any SidebarGitHosting) {}
    func scheduleWorkspacePullRequestRefresh(workspaceId: UUID, panelId: UUID, reason: String) {
        scheduledRefreshes.append((workspaceId, panelId, reason))
        trackedPanelIdsByWorkspace[workspaceId, default: []].insert(panelId)
    }
    func seedWorkspacePullRequestRefreshIfNeeded(
        workspaceId: UUID,
        panelId: UUID,
        directory: String,
        branch: String,
        reason: String
    ) {
        guard let normalizedBranch = GitMetadataService.normalizedBranchName(branch) else { return }
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let source = SourceIdentity(
            directory: directory.normalizedGitProbeDirectory,
            branch: normalizedBranch
        )
        guard sourceByKey[key] != source else { return }
        sourceByKey[key] = source
        guard !PullRequestProbeService.shouldSkipLookup(branch: normalizedBranch) else { return }
        scheduleWorkspacePullRequestRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason
        )
    }
    func refreshTrackedWorkspacePullRequestsIfNeeded(reason: String) {}
    func sidebarPullRequestPollingSettingsDidChange() {}
    func handleWorkspacePullRequestCommandHint(workspaceId: UUID, panelId: UUID, action: String, target: String?) {}
    func clearWorkspacePullRequestTracking(workspaceId: UUID, panelId: UUID) {
        clearedTrackingKeys.append((workspaceId, panelId))
        trackedPanelIdsByWorkspace[workspaceId]?.remove(panelId)
        sourceByKey.removeValue(forKey: WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId))
    }
    func clearWorkspacePullRequestMetadata(workspaceId: UUID, panelId: UUID) {}
    func clearWorkspacePullRequestTracking(workspaceId: UUID) {
        clearedTrackingWorkspaceIds.append(workspaceId)
        trackedPanelIdsByWorkspace[workspaceId] = []
        sourceByKey = sourceByKey.filter { $0.key.workspaceId != workspaceId }
    }
    func resetWorkspacePullRequestRefreshState() {
        resetCount += 1
        trackedPanelIdsByWorkspace.removeAll()
        sourceByKey.removeAll()
    }
    func workspacePullRequestTrackedPanelIds(workspaceId: UUID) -> Set<UUID> {
        trackedPanelIdsByWorkspace[workspaceId] ?? []
    }
}

/// A `CommandRunning` that fails the test if any subprocess is spawned.
struct ForbiddenCommandRunner: CommandRunning {
    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        CommandResult(
            stdout: "",
            stderr: "unexpected subprocess: \(executable) \(arguments.joined(separator: " "))",
            exitStatus: 1,
            timedOut: false,
            executionError: "unexpected subprocess"
        )
    }
}

extension GitWorkspaceMetadata {
    static func repository(branch: String, isDirty: Bool = false) -> GitWorkspaceMetadata {
        GitWorkspaceMetadata(
            isRepository: true,
            branch: branch,
            isDirty: isDirty,
            indexSignature: "index",
            indexContentSignature: "content",
            headSignature: "head"
        )
    }

    static let nonRepository = GitWorkspaceMetadata(
        isRepository: false,
        branch: nil,
        isDirty: false,
        indexSignature: nil,
        indexContentSignature: nil,
        headSignature: nil
    )
}

/// A staged PR executor whose repository-fetch calls remain suspended until
/// the test explicitly releases them. This makes overlap and stale-completion
/// ordering deterministic without sleeps or live GitHub traffic.
actor GatedPullRequestRefreshExecutor: PullRequestRefreshExecuting {
    private struct FetchWaiter {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var fetchGateContinuations: [CheckedContinuation<Void, Never>] = []
    private var fetchWaiters: [FetchWaiter] = []
    private(set) var resolutionCount = 0
    private(set) var fetchCount = 0
    private(set) var allowCachedResultsRequests: [Bool] = []

    func resolveCandidateSeeds(
        _ seeds: [WorkspacePullRequestCandidateSeed]
    ) async -> WorkspacePullRequestCandidateResolution {
        resolutionCount += 1
        let candidates = seeds.map {
            WorkspacePullRequestCandidate(
                workspaceId: $0.workspaceId,
                panelId: $0.panelId,
                branch: $0.branch,
                repoSlugs: ["owner/repo"]
            )
        }
        let branches = Set(candidates.map(\.branch))
        return WorkspacePullRequestCandidateResolution(
            candidates: candidates,
            candidateBranchesByRepo: ["owner/repo": branches],
            repoDirectoriesBySlug: ["owner/repo": "/tmp/repo"]
        )
    }

    func fetchRepoResults(
        candidateResolution: WorkspacePullRequestCandidateResolution,
        cacheBySlug: [String: WorkspacePullRequestRepoCacheEntry],
        now: Date,
        allowCachedResults: Bool
    ) async -> [String: WorkspacePullRequestRepoFetchResult] {
        fetchCount += 1
        allowCachedResultsRequests.append(allowCachedResults)
        resumeSatisfiedFetchWaiters()
        await withCheckedContinuation { continuation in
            fetchGateContinuations.append(continuation)
        }

        var pullRequestsByBranch: [String: GitHubPullRequestProbeItem] = [:]
        for branch in candidateResolution.candidateBranchesByRepo["owner/repo"] ?? [] {
            pullRequestsByBranch[branch] = GitHubPullRequestProbeItem(
                number: 99,
                state: "OPEN",
                url: "https://github.com/owner/repo/pull/99",
                updatedAt: "2026-07-12T00:00:00Z",
                mergedAt: nil,
                headRefName: branch,
                baseRefName: "main"
            )
        }
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: now,
            pullRequestsByBranch: pullRequestsByBranch
        )
        return ["owner/repo": .success(entry, usedCache: false, transientBranches: [])]
    }

    func waitForFetchCount(_ minimumCount: Int) async {
        guard fetchCount < minimumCount else { return }
        await withCheckedContinuation { continuation in
            fetchWaiters.append(FetchWaiter(
                minimumCount: minimumCount,
                continuation: continuation
            ))
        }
    }

    func releaseNextFetch() {
        guard !fetchGateContinuations.isEmpty else { return }
        fetchGateContinuations.removeFirst().resume()
    }

    private func resumeSatisfiedFetchWaiters() {
        let ready = fetchWaiters.filter { $0.minimumCount <= fetchCount }
        fetchWaiters.removeAll { $0.minimumCount <= fetchCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
