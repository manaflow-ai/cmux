import Foundation
import CmuxGit

// MARK: - Detached pull-request lookup execution and main-actor apply.

extension PullRequestPollService {
    struct RefreshRequest {
        let seeds: [WorkspacePullRequestCandidateSeed]
        let keys: [WorkspaceGitProbeKey]
        let sources: [WorkspaceGitProbeKey: SourceIdentity]
        let cacheBySlug: [String: WorkspacePullRequestRepoCacheEntry]
        let now: Date
        let allowCachedResults: Bool
        let reason: String
    }

    func startWorkspacePullRequestRefresh(_ request: RefreshRequest) {
        let gitMetadataService = gitMetadataService
        let probeService = probeService
        workspacePullRequestRefreshTask = Task.detached(priority: .utility) { [weak self] in
            let candidateResolution = await probeService.resolveCandidateSeeds(
                request.seeds,
                gitMetadata: gitMetadataService
            )
            guard !Task.isCancelled else { return }
            let repoResults = await probeService.fetchRepoResults(
                repoDirectoriesBySlug: candidateResolution.repoDirectoriesBySlug,
                candidateBranchesByRepo: candidateResolution.candidateBranchesByRepo,
                cacheBySlug: request.cacheBySlug,
                now: request.now,
                allowCachedResults: request.allowCachedResults
            )
            let results = PullRequestProbeService.resolveRefreshResults(
                candidates: candidateResolution.candidates,
                repoResults: repoResults
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.workspacePullRequestRefreshTask = nil
                self.applyWorkspacePullRequestRefreshResults(
                    results,
                    repoResults: repoResults,
                    requestedKeys: request.keys,
                    requestedSourceByKey: request.sources,
                    now: Date(),
                    reason: request.reason
                )
            }
        }
    }
}
