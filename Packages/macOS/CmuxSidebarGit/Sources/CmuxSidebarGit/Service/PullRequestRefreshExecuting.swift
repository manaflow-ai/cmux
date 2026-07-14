import Foundation
import CmuxGit

/// The detached stages of one pull-request refresh.
///
/// Keeping these stages behind a `Sendable` executor lets the main-actor poll
/// owner retain sole authority over scheduling and application while tests
/// deterministically gate the actual repository-fetch boundary.
protocol PullRequestRefreshExecuting: Sendable {
    func resolveCandidateSeeds(
        _ seeds: [WorkspacePullRequestCandidateSeed]
    ) async -> WorkspacePullRequestCandidateResolution

    func fetchRepoResults(
        candidateResolution: WorkspacePullRequestCandidateResolution,
        cacheBySlug: [String: WorkspacePullRequestRepoCacheEntry],
        now: Date,
        allowCachedResults: Bool
    ) async -> [String: WorkspacePullRequestRepoFetchResult]
}

struct LivePullRequestRefreshExecutor: PullRequestRefreshExecuting {
    let gitMetadataService: GitMetadataService
    let probeService: PullRequestProbeService

    func resolveCandidateSeeds(
        _ seeds: [WorkspacePullRequestCandidateSeed]
    ) async -> WorkspacePullRequestCandidateResolution {
        await probeService.resolveCandidateSeeds(
            seeds,
            gitMetadata: gitMetadataService
        )
    }

    func fetchRepoResults(
        candidateResolution: WorkspacePullRequestCandidateResolution,
        cacheBySlug: [String: WorkspacePullRequestRepoCacheEntry],
        now: Date,
        allowCachedResults: Bool
    ) async -> [String: WorkspacePullRequestRepoFetchResult] {
        await probeService.fetchRepoResults(
            repoDirectoriesBySlug: candidateResolution.repoDirectoriesBySlug,
            candidateBranchesByRepo: candidateResolution.candidateBranchesByRepo,
            cacheBySlug: cacheBySlug,
            now: now,
            allowCachedResults: allowCachedResults
        )
    }
}
