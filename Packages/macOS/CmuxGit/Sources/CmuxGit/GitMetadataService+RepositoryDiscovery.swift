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
        let traversal = GitConfigBranchTraversal(
            repository: repository,
            branchContext: branchContext,
            deadline: deadline
        )
        let traversalResult = traversal.remoteVResult()
        let output: String?
        if traversalResult.isComplete {
            output = traversalResult.output
        } else if traversalResult.isUnsafe {
            output = nil
        } else {
            output = await gitRemoteVFallback(
                repository: repository,
                deadline: deadline
            )
        }
        let repositorySlugs = output.map {
            Self.githubRepositorySlugs(fromGitRemoteVOutput: $0)
        } ?? []
        return GitRepositoryDiscoverySnapshot(
            repositorySlugs: repositorySlugs,
            checkedOutBranch: references.checkedOutBranch
        )
    }
}
