public import Foundation
public import CmuxProcess

/// Resolves GitHub pull-request badges for workspace panels: which PR (if any)
/// is open/merged/closed for each panel's branch.
///
/// The pipeline has three stages, called by the app's orchestration in order:
/// 1. ``resolveCandidateSeeds(_:gitMetadata:)`` — map each panel's directory to
///    host-qualified repository references (reading git config via
///    ``GitMetadataService``).
/// 2. ``fetchRepoResults(repoDirectoriesByReference:candidateBranchesByRepo:cacheByReference:now:allowCachedResults:)``
///    — fetch each repository's recent PRs (REST, paged) using the reference's
///    host, with per-branch fallback lookups, honoring the caller-owned repo
///    cache.
/// 3. ``resolveRefreshResults(candidates:repoResults:)`` — match candidates
///    against the fetched data into per-panel ``WorkspacePullRequestRefreshResult``s.
///
/// Like ``GitMetadataService`` it is a stateless `Sendable` value with
/// `nonisolated async` reads (off the caller's actor, parallel across calls;
/// see that type's `Important` note on `NonisolatedNonsendingByDefault`). The
/// repo cache is owned by the caller and passed in, so the service holds no
/// mutable state. Authentication uses `GH_TOKEN`/`GITHUB_TOKEN` for
/// `github.com`, then `gh auth token --hostname <host>` via the injected
/// ``CmuxProcess/CommandRunning`` for each host.
public struct PullRequestProbeService: Sendable {
    /// Runs `gh auth token --hostname <host>` for API auth headers.
    let commandRunner: any CommandRunning

    /// The environment used for token resolution.
    ///
    /// Carries `GH_TOKEN`/`GITHUB_TOKEN` (consulted only for `github.com`) and
    /// the ambient `GH_ENTERPRISE_TOKEN`/`GITHUB_ENTERPRISE_TOKEN`, which are
    /// rejected for enterprise hosts (see ``authToken(for:)``). Injected so tests
    /// stay off `ProcessInfo.processInfo.environment`.
    let environment: [String: String]

    /// Debug-log sink for probe diagnostics (the app injects its debug logger
    /// in DEBUG builds; defaults to a no-op).
    let debugLog: @Sendable (String) -> Void

    /// Creates a pull-request probe service.
    ///
    /// - Parameters:
    ///   - commandRunner: Runs `gh auth token --hostname <host>`; tests pass a fake.
    ///   - environment: The environment read for tokens; defaults to the process
    ///     environment.
    ///   - debugLog: Optional diagnostics sink; defaults to a no-op.
    public init(
        commandRunner: any CommandRunning = CommandRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.commandRunner = commandRunner
        self.environment = environment
        self.debugLog = debugLog
    }

    // MARK: Tuning constants

    /// How long a fetched repo cache entry satisfies periodic refreshes.
    static let repoCacheLifetime: TimeInterval = 15
    /// REST page size for the recent-PRs fetch.
    static let repoPageSize = 100
    /// Maximum REST pages fetched per repository.
    static let repoPageLimit = 2
    /// Per-request timeout for GitHub API calls and the `gh auth token` probe.
    static let probeTimeout: TimeInterval = 5.0
    /// Merged PRs older than this no longer earn a badge.
    static let mergedBadgeStaleAfter: TimeInterval = 14 * 24 * 60 * 60
    /// How often a panel showing a terminal (merged/closed) PR is re-checked.
    /// Public because the app's poll scheduling uses the same interval.
    public static let terminalStateSweepInterval: TimeInterval = 15 * 60

    // MARK: Stage 1 — candidate resolution

    /// Resolves candidate seeds against each directory's GitHub remotes.
    ///
    /// Directories are resolved to host-qualified references once each
    /// (deduplicated across seeds); a seed whose directory has no parseable
    /// remote yields a candidate with empty
    /// ``WorkspacePullRequestCandidate/repoReferences``.
    ///
    /// - Parameters:
    ///   - seeds: One per panel wanting a badge.
    ///   - gitMetadata: The git-metadata reader used for remote resolution.
    /// - Returns: The candidates plus repo-keyed indexes for the fetch stage.
    public nonisolated func resolveCandidateSeeds(
        _ seeds: [WorkspacePullRequestCandidateSeed],
        gitMetadata: GitMetadataService
    ) async -> WorkspacePullRequestCandidateResolution {
        var candidates: [WorkspacePullRequestCandidate] = []
        candidates.reserveCapacity(seeds.count)
        var candidateBranchesByRepo: [GitHubRepositoryReference: Set<String>] = [:]
        var repoDirectoriesByReference: [GitHubRepositoryReference: String] = [:]
        var repoReferencesByDirectory: [String: [GitHubRepositoryReference]] = [:]

        for seed in seeds {
            let repoReferences: [GitHubRepositoryReference]
            if let directory = seed.directory {
                if let cachedRepoReferences = repoReferencesByDirectory[directory] {
                    repoReferences = cachedRepoReferences
                } else {
                    let resolvedRepoReferences = await gitMetadata.repositoryReferences(forDirectory: directory)
                    repoReferencesByDirectory[directory] = resolvedRepoReferences
                    repoReferences = resolvedRepoReferences
                }
            } else {
                repoReferences = []
            }

            candidates.append(
                WorkspacePullRequestCandidate(
                    workspaceId: seed.workspaceId,
                    panelId: seed.panelId,
                    branch: seed.branch,
                    repoReferences: repoReferences
                )
            )

            for reference in repoReferences {
                candidateBranchesByRepo[reference, default: []].insert(seed.branch)
                if let directory = seed.directory, repoDirectoriesByReference[reference] == nil {
                    repoDirectoriesByReference[reference] = directory
                }
            }
        }

        return WorkspacePullRequestCandidateResolution(
            candidates: candidates,
            candidateBranchesByRepo: candidateBranchesByRepo,
            repoDirectoriesByReference: repoDirectoriesByReference
        )
    }

    // MARK: Stage 3 — result resolution (pure)

    /// Matches candidates against fetched repo results into per-panel outcomes.
    ///
    /// For each candidate the first reference (in remote preference order) with
    /// a PR for the branch wins; otherwise a transient failure anywhere
    /// downgrades the outcome to
    /// ``WorkspacePullRequestRefreshResult/Resolution/transientFailure`` (so an
    /// existing badge is kept), else `notFound`.
    public static func resolveRefreshResults(
        candidates: [WorkspacePullRequestCandidate],
        repoResults: [GitHubRepositoryReference: WorkspacePullRequestRepoFetchResult]
    ) -> [WorkspacePullRequestRefreshResult] {
        candidates.map { candidate in
            if candidate.repoReferences.isEmpty {
                return WorkspacePullRequestRefreshResult(
                    workspaceId: candidate.workspaceId,
                    panelId: candidate.panelId,
                    resolution: .unsupportedRepository,
                    usedCachedRepoData: false
                )
            }

            var matchedPullRequest: GitHubPullRequestProbeItem?
            var matchedPullRequestUsedCache = false
            var sawTransientFailure = false
            var sawCachedSuccess = false

            let attemptedReferences = candidate.repoReferences.filter { repoResults[$0] != nil }
            if attemptedReferences.isEmpty {
                return WorkspacePullRequestRefreshResult(
                    workspaceId: candidate.workspaceId,
                    panelId: candidate.panelId,
                    resolution: .unsupportedRepository,
                    usedCachedRepoData: false
                )
            }

            for reference in attemptedReferences {
                guard let repoResult = repoResults[reference] else { continue }
                switch repoResult {
                case .success(let cacheEntry, let usedCache, let transientBranches):
                    if usedCache {
                        sawCachedSuccess = true
                    }
                    if let candidateMatch = cacheEntry.pullRequestsByBranch[candidate.branch] {
                        matchedPullRequest = candidateMatch
                        matchedPullRequestUsedCache = usedCache
                        break
                    }
                    if transientBranches.contains(candidate.branch) {
                        sawTransientFailure = true
                    }
                case .transientFailure:
                    sawTransientFailure = true
                }
            }

            let resolution: WorkspacePullRequestRefreshResult.Resolution
            let usedCachedRepoData: Bool
            if let matchedPullRequest,
               let status = PullRequestStatus(githubState: matchedPullRequest.state) {
                resolution = .resolved(
                    WorkspacePullRequestResolvedItem(
                        number: matchedPullRequest.number,
                        urlString: matchedPullRequest.url,
                        statusRawValue: status.rawValue,
                        branch: candidate.branch
                    )
                )
                usedCachedRepoData = matchedPullRequestUsedCache
            } else if sawTransientFailure {
                resolution = .transientFailure
                usedCachedRepoData = false
            } else {
                resolution = .notFound
                usedCachedRepoData = sawCachedSuccess
            }

            return WorkspacePullRequestRefreshResult(
                workspaceId: candidate.workspaceId,
                panelId: candidate.panelId,
                resolution: resolution,
                usedCachedRepoData: usedCachedRepoData
            )
        }
    }

    // MARK: Refresh policy (pure)

    /// Whether a refresh triggered by `reason` may serve repo data from the
    /// caller's cache (periodic polls may; user-driven refreshes must not).
    public static func refreshAllowsRepoCache(reason: String) -> Bool {
        let periodicPrefixes = [
            "periodicPoll",
            "selectedPeriodicPoll",
            "timer",
        ]
        return periodicPrefixes.contains { prefix in
            reason == prefix || reason.hasPrefix("\(prefix).")
        }
    }

    /// Whether a panel's pull request is due for a refresh.
    ///
    /// Due when its next poll time has passed, or — for a badge already in a
    /// terminal state (merged/closed) — when the slower terminal-state sweep
    /// interval has elapsed since the last terminal refresh.
    public static func shouldRefresh(
        now: Date,
        nextPollAt: Date?,
        lastTerminalStateRefreshAt: Date?,
        currentStatus: PullRequestStatus?
    ) -> Bool {
        let nextPollAt = nextPollAt ?? .distantPast
        if nextPollAt <= now {
            return true
        }

        guard let currentStatus,
              currentStatus != .open else {
            return false
        }

        let lastTerminalRefreshAt = lastTerminalStateRefreshAt ?? .distantPast
        return now.timeIntervalSince(lastTerminalRefreshAt) >= Self.terminalStateSweepInterval
    }

    /// Whether PR lookup should be skipped entirely for `branch` (default
    /// branches never get a badge).
    public static func shouldSkipLookup(branch: String) -> Bool {
        switch GitMetadataService.normalizedBranchName(branch) {
        case "main", "master":
            return true
        default:
            return false
        }
    }
}
