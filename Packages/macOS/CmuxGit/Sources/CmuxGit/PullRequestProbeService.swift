public import Foundation
public import CmuxFoundation

/// Resolves GitHub pull-request badges for workspace panels: which PR (if any)
/// is open/merged/closed for each panel's branch.
///
/// The pipeline has three stages, called by the app's orchestration in order:
/// 1. ``resolveCandidateSeeds(_:gitMetadata:)`` — map each panel's directory to
///    its GitHub `owner/name` slugs (reading git config via ``GitMetadataService``).
/// 2. ``fetchRepoResults(repoDirectoriesBySlug:candidateBranchesByRepo:cacheBySlug:now:allowCachedResults:)``
///    — fetch each repository's recent PRs (REST, paged), with per-branch
///    fallback lookups, honoring the caller-owned repo cache.
/// 3. ``resolveRefreshResults(candidates:repoResults:)`` — match candidates
///    against the fetched data into per-panel ``WorkspacePullRequestRefreshResult``s.
///
/// Like ``GitMetadataService`` it is a stateless `Sendable` value with
/// `nonisolated async` reads (off the caller's actor, parallel across calls;
/// see that type's `Important` note on `NonisolatedNonsendingByDefault`). The
/// repo cache is owned by the caller and passed in. The service only retains a
/// short-lived auth-header cache so periodic refreshes do not spawn `gh auth
/// token` on every pass. Authentication uses `GH_TOKEN`/`GITHUB_TOKEN` or
/// `gh auth token` via the injected ``CmuxProcess/CommandRunning``.
public struct PullRequestProbeService: Sendable {
    /// Runs `gh auth token` for the API auth header. Injected so tests supply a
    /// fake without spawning a process.
    let commandRunner: any CommandRunning

    /// Caches `gh auth token` results so refresh passes do not repeatedly spawn
    /// the GitHub CLI when the app has no environment token.
    let authHeaderCache: GitHubAuthHeaderCache

    /// Debug-log sink for probe diagnostics (the app injects its debug logger
    /// in DEBUG builds; defaults to a no-op).
    let debugLog: @Sendable (String) -> Void

    /// Creates a pull-request probe service.
    ///
    /// - Parameters:
    ///   - commandRunner: Runs `gh auth token`; tests pass a fake.
    ///   - debugLog: Optional diagnostics sink; defaults to a no-op.
    public init(
        commandRunner: any CommandRunning = CommandRunner(),
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.commandRunner = commandRunner
        self.authHeaderCache = GitHubAuthHeaderCache()
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
    /// Directories are resolved to `owner/name` slugs once each (deduplicated
    /// across seeds); a seed whose directory has no GitHub remote yields a
    /// candidate with empty ``WorkspacePullRequestCandidate/repoSlugs``.
    ///
    /// Each directory's checked-out branch is also re-detected on disk (once
    /// per directory per pass) and overrides the seed's projected branch, so a
    /// stale sidebar branch projection cannot pin the PR association to an old
    /// branch. Detached HEAD or a missing repository falls back to the seed's
    /// branch; a re-detected default branch (main/master) stays on the
    /// candidate but is excluded from the per-repo lookup index.
    ///
    /// - Parameters:
    ///   - seeds: One per panel wanting a badge.
    ///   - gitMetadata: The git-metadata reader used for slug resolution.
    /// - Returns: The candidates plus repo-keyed indexes for the fetch stage.
    public nonisolated func resolveCandidateSeeds(
        _ seeds: [WorkspacePullRequestCandidateSeed],
        gitMetadata: GitMetadataService
    ) async -> WorkspacePullRequestCandidateResolution {
        var candidates: [WorkspacePullRequestCandidate] = []
        candidates.reserveCapacity(seeds.count)
        var candidateBranchesByRepo: [String: Set<String>] = [:]
        var repoDirectoriesBySlug: [String: String] = [:]
        var repoSlugsByDirectory: [String: [String]] = [:]
        var checkedOutBranchesByDirectory: [String: GitCheckedOutBranch] = [:]

        for seed in seeds {
            let repoSlugs: [String]
            let checkedOutBranch: GitCheckedOutBranch
            if let directory = seed.directory {
                if let cachedRepoSlugs = repoSlugsByDirectory[directory] {
                    repoSlugs = cachedRepoSlugs
                } else {
                    let resolvedRepoSlugs = await gitMetadata.repositorySlugs(forDirectory: directory)
                    repoSlugsByDirectory[directory] = resolvedRepoSlugs
                    repoSlugs = resolvedRepoSlugs
                }

                if let cachedBranch = checkedOutBranchesByDirectory[directory] {
                    checkedOutBranch = cachedBranch
                } else {
                    let resolvedBranch = await gitMetadata.checkedOutBranch(forDirectory: directory)
                    checkedOutBranchesByDirectory[directory] = resolvedBranch
                    checkedOutBranch = resolvedBranch
                }
            } else {
                repoSlugs = []
                checkedOutBranch = .notARepository
            }

            let projectedBranch = GitMetadataService.normalizedBranchName(seed.branch) ?? seed.branch
            let candidateBranch: String
            let branchReadFailed: Bool
            switch checkedOutBranch {
            case .branch(let detectedBranch):
                candidateBranch = detectedBranch
                branchReadFailed = false
            case .detached, .notARepository:
                // A legitimate non-branch checkout (or a vanished repository)
                // keeps the projected association, matching pre-detection
                // behavior.
                candidateBranch = projectedBranch
                branchReadFailed = false
            case .unreadable:
                // The repository exists but its branch cannot be verified;
                // resolve as transient so an existing badge is kept instead
                // of re-matching a possibly stale projected branch.
                candidateBranch = projectedBranch
                branchReadFailed = true
            }
            let shouldLookupBranch = !branchReadFailed && !Self.shouldSkipLookup(branch: candidateBranch)
            candidates.append(
                WorkspacePullRequestCandidate(
                    workspaceId: seed.workspaceId,
                    panelId: seed.panelId,
                    branch: candidateBranch,
                    repoSlugs: repoSlugs,
                    branchReadFailed: branchReadFailed
                )
            )

            for repoSlug in repoSlugs {
                guard shouldLookupBranch else { continue }
                candidateBranchesByRepo[repoSlug, default: []].insert(candidateBranch)
                if let directory = seed.directory, repoDirectoriesBySlug[repoSlug] == nil {
                    repoDirectoriesBySlug[repoSlug] = directory
                }
            }
        }

        return WorkspacePullRequestCandidateResolution(
            candidates: candidates,
            candidateBranchesByRepo: candidateBranchesByRepo,
            repoDirectoriesBySlug: repoDirectoriesBySlug
        )
    }

    // MARK: Stage 3 — result resolution (pure)

    /// Matches candidates against fetched repo results into per-panel outcomes.
    ///
    /// For each candidate the first repo (in slug preference order) with a PR
    /// for the branch wins; otherwise a transient failure anywhere downgrades
    /// the outcome to ``WorkspacePullRequestRefreshResult/Resolution/transientFailure``
    /// (so an existing badge is kept), else `notFound`. A candidate whose
    /// checked-out branch could not be verified resolves `transientFailure`
    /// without matching (keeping any badge); a candidate on a default branch
    /// (main/master) resolves `notFound` without matching, so returning to
    /// the default branch clears any badge.
    public static func resolveRefreshResults(
        candidates: [WorkspacePullRequestCandidate],
        repoResults: [String: WorkspacePullRequestRepoFetchResult]
    ) -> [WorkspacePullRequestRefreshResult] {
        candidates.map { candidate in
            if candidate.repoSlugs.isEmpty {
                return WorkspacePullRequestRefreshResult(
                    workspaceId: candidate.workspaceId,
                    panelId: candidate.panelId,
                    resolution: .unsupportedRepository,
                    usedCachedRepoData: false
                )
            }

            if candidate.branchReadFailed {
                return WorkspacePullRequestRefreshResult(
                    workspaceId: candidate.workspaceId,
                    panelId: candidate.panelId,
                    resolution: .transientFailure,
                    usedCachedRepoData: false
                )
            }

            if Self.shouldSkipLookup(branch: candidate.branch) {
                return WorkspacePullRequestRefreshResult(
                    workspaceId: candidate.workspaceId,
                    panelId: candidate.panelId,
                    resolution: .notFound,
                    usedCachedRepoData: false
                )
            }

            var matchedPullRequest: GitHubPullRequestProbeItem?
            var matchedPullRequestUsedCache = false
            var sawTransientFailure = false
            var sawCachedSuccess = false

            for repoSlug in candidate.repoSlugs {
                guard let repoResult = repoResults[repoSlug] else { continue }
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
