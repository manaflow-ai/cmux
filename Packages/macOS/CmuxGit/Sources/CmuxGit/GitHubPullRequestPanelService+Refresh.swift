import CmuxFoundation
import Foundation

extension GitHubPullRequestPanelService {
    /// Refreshes the branch's pull-request content and stores successful results in the actor cache.
    public func refresh(for input: PullRequestWorkspaceInput) async throws -> PullRequestPanelContent {
        let context = try await resolvedContext(for: input)
        try Task.checkCancellation()
        let request = coalescedRefreshRequest(for: context)
        return try await withTaskCancellationHandler {
            defer {
                finishCoalescedRefreshWaiter(
                    request.waiterIdentifier,
                    requestIdentifier: request.identifier,
                    for: context
                )
            }
            return try await request.task.value
        } onCancel: {
            Task {
                await self.finishCoalescedRefreshWaiter(
                    request.waiterIdentifier,
                    requestIdentifier: request.identifier,
                    for: context
                )
            }
        }
    }

    func performRefresh(for context: PullRequestPanelContext) async throws -> PullRequestPanelContent {
        try Task.checkCancellation()
        let refreshSequence = beginRefresh(for: context)
        defer { finishRefresh(refreshSequence, for: context) }
        let viewResult = await commandRunner.run(
            directory: context.repositoryRoot,
            executable: "gh",
            arguments: [
                "pr", "view", context.branch, "--repo", context.repositorySlug, "--json",
                "number,title,state,url,statusCheckRollup,updatedAt,isDraft,mergeable,reviewDecision,mergeStateStatus,autoMergeRequest,baseRefName,headRefName,baseRefOid,headRefOid",
            ],
            timeout: 10
        )
        try Task.checkCancellation()

        if isNoPullRequest(viewResult) {
            let content = PullRequestPanelContent.noPullRequest(context)
            storeCachedContentIfLatest(content, for: context, refreshSequence: refreshSequence)
            return content
        }
        let viewOutput = try requiredOutput(from: viewResult, failure: .refreshFailed)
        let pullRequest: GitHubPullRequest = try decode(viewOutput)
        guard pullRequest.headRefName == context.branch else {
            throw PullRequestPanelServiceError.refreshFailed
        }

        let cachedSnapshot: PullRequestPanelSnapshot?
        if case .pullRequest(let snapshot)? = cacheByContext[context],
           snapshot.pullRequest.number == pullRequest.number {
            cachedSnapshot = snapshot
        } else {
            cachedSnapshot = nil
        }
        let shouldFetchComments = cachedSnapshot?.pullRequest.updatedAt != pullRequest.updatedAt

        async let checks = fetchChecks(number: pullRequest.number, context: context)
        async let comments: PullRequestReviewCommentsPayload? = shouldFetchComments
            ? fetchComments(number: pullRequest.number, context: context)
            : nil
        async let settings = fetchMergeSettings(context: context)
        let (resolvedChecks, resolvedComments, resolvedSettings) = try await (checks, comments, settings)
        try Task.checkCancellation()

        let checksStatus = PullRequestChecksStatus.derive(from: pullRequest.statusCheckRollup)
        let snapshot = PullRequestPanelSnapshot(
            context: context,
            pullRequest: pullRequest,
            checks: resolvedChecks,
            checksStatus: checksStatus,
            unresolvedReviewThreadCount: shouldFetchComments
                ? resolvedComments?.unresolvedThreadCount
                : cachedSnapshot?.unresolvedReviewThreadCount,
            mergeMethods: PullRequestMergeMethod.orderedAllowed(
                settings: resolvedSettings,
                defaultMethod: resolvedSettings.viewerDefaultMergeMethod
            )
        )
        let content = PullRequestPanelContent.pullRequest(snapshot)
        storeCachedContentIfLatest(content, for: context, refreshSequence: refreshSequence)
        return content
    }

    nonisolated func resolvedContext(
        for input: PullRequestWorkspaceInput
    ) async throws -> PullRequestPanelContext {
        let directory = input.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty,
              let repository = GitMetadataService.resolveGitRepository(containing: directory) else {
            throw PullRequestPanelServiceError.notGitRepository
        }
        let branch: String
        switch GitMetadataService.gitCheckedOutBranch(repository: repository) {
        case .branch(let value): branch = value
        case .detached, .unreadable: throw PullRequestPanelServiceError.detachedHead
        case .notARepository: throw PullRequestPanelServiceError.notGitRepository
        }
        guard let repositorySlug = await gitMetadataService
            .repositorySlugs(forDirectory: repository.workTreeRoot)
            .first else {
            throw PullRequestPanelServiceError.noGitHubRemote
        }
        return PullRequestPanelContext(
            repositoryRoot: repository.workTreeRoot,
            branch: branch,
            repositorySlug: repositorySlug
        )
    }

    nonisolated func fetchChecks(
        number: Int,
        context: PullRequestPanelContext
    ) async throws -> [GitHubPullRequestCheck] {
        let result = await commandRunner.run(
            directory: context.repositoryRoot,
            executable: "gh",
            arguments: [
                "pr", "checks", String(number),
                "--repo", context.repositorySlug,
                "--json", "name,state,link",
            ],
            timeout: 10
        )
        try Task.checkCancellation()
        if result.stderr?.localizedCaseInsensitiveContains("no checks reported") == true {
            return []
        }
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0 || result.exitStatus == 8 else {
            throw classifiedFailure(result, fallback: .refreshFailed)
        }
        guard let output = result.stdout else { throw PullRequestPanelServiceError.invalidResponse }
        return try decode(output)
    }

    nonisolated func fetchComments(
        number: Int,
        context: PullRequestPanelContext
    ) async -> PullRequestReviewCommentsPayload? {
        // The v1 data contract intentionally uses the exact `comments` query. Current gh
        // versions omit review-thread metadata; the decoder reports nil unless it appears.
        let result = await commandRunner.run(
            directory: context.repositoryRoot,
            executable: "gh",
            arguments: [
                "pr", "view", String(number),
                "--repo", context.repositorySlug,
                "--json", "comments",
                "--jq", "{comments: [.comments[] | select(.threadId != null and .isResolved != null) | {threadId, isResolved}]}",
            ],
            timeout: 10
        )
        guard let output = try? requiredOutput(from: result, failure: .refreshFailed) else {
            return nil
        }
        return try? decode(output)
    }

    nonisolated func fetchMergeSettings(
        context: PullRequestPanelContext
    ) async throws -> GitHubRepositoryMergeSettings {
        let result = await commandRunner.run(
            directory: context.repositoryRoot,
            executable: "gh",
            arguments: [
                "repo", "view", context.repositorySlug, "--json",
                "mergeCommitAllowed,rebaseMergeAllowed,squashMergeAllowed,viewerDefaultMergeMethod",
            ],
            timeout: 10
        )
        try Task.checkCancellation()
        let output = try requiredOutput(from: result, failure: .refreshFailed)
        return try decode(output)
    }
}
