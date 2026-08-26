import Dispatch
import Foundation

extension GitMetadataService {
    /// Resolves remote slugs and branch state from one reference snapshot.
    @concurrent
    public nonisolated func repositoryDiscoverySnapshot(
        forDirectory directory: String
    ) async -> GitRepositoryDiscoverySnapshot {
        guard let repository = Self.resolveGitRepository(containing: directory) else {
            return GitRepositoryDiscoverySnapshot(
                repositorySlugs: [],
                checkedOutBranch: .notARepository
            )
        }

        let deadline = DispatchTime.now()
            + max(5, safetyConfiguration.gitStatusWallTime * 8)
        let references = await gitReferenceSnapshot(
            repository: repository,
            deadline: deadline
        )
        let branchContext = GitConfigBranchContext.resolved(references.branchName)
        let traversalResult = await gitRemoteVTraversal(
            repository: repository,
            branchContext: branchContext,
            deadline: deadline
        )
        let output: String?
        let remoteReadFailed: Bool
        if traversalResult.isComplete {
            output = traversalResult.output
            remoteReadFailed = false
        } else if traversalResult.isUnsafe {
            output = nil
            remoteReadFailed = true
        } else {
            output = await gitRemoteVFallback(
                repository: repository,
                deadline: deadline
            )
            remoteReadFailed = output == nil
        }
        let repositorySlugs = output.map {
            Self.githubRepositorySlugs(fromGitRemoteVOutput: $0)
        } ?? []
        return GitRepositoryDiscoverySnapshot(
            repositorySlugs: repositorySlugs,
            checkedOutBranch: references.checkedOutBranch,
            remoteReadFailed: remoteReadFailed
        )
    }

    /// Runs the bounded config graph walk on the blocking-I/O lane.
    @concurrent
    nonisolated func gitRemoteVTraversal(
        repository: ResolvedGitRepository,
        branchContext: GitConfigBranchContext,
        deadline: DispatchTime
    ) async -> GitConfigRemoteTraversalResult {
        let traversal = GitConfigBranchTraversal(
            repository: repository,
            branchContext: branchContext,
            deadline: deadline
        )
        let cancellationSignal = WorkspaceChangesCancellationSignal()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.blockingStatusQueue.async {
                    let result = cancellationSignal.withCurrentBinding {
                        traversal.remoteVResult()
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellationSignal.cancel()
        }
    }
}
