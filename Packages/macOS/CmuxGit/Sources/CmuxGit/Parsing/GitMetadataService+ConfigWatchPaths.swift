import Dispatch
import Foundation

extension GitMetadataService {
    /// Builds one bounded branch-aware config-path map for a repository tree.
    nonisolated func branchAwareConfigPathsByRepository(
        repository: ResolvedGitRepository,
        safetyConfiguration: GitMetadataSafetyConfiguration
    ) async -> GitMetadataWatchInputs {
        let deadline = DispatchTime.now()
            + max(5, safetyConfiguration.gitStatusWallTime * 8)
        let result = await collectBranchAwareConfigPaths(
            repository: repository,
            depth: 0,
            safetyConfiguration: safetyConfiguration,
            visitedRoots: [],
            remainingRepositoryCount: 32,
            deadline: deadline
        )
        return GitMetadataWatchInputs(
            configPathsByRepository: result.paths,
            indexSnapshotsByRepository: result.indexSnapshots,
            forceWorkTreeRootRepositories: result.forceWorkTreeRoots
        )
    }

    private nonisolated func collectBranchAwareConfigPaths(
        repository: ResolvedGitRepository,
        depth: Int,
        safetyConfiguration: GitMetadataSafetyConfiguration,
        visitedRoots: Set<String>,
        remainingRepositoryCount: Int,
        deadline: DispatchTime
    ) async -> (
        paths: [String: [String]],
        indexSnapshots: [String: GitIndexSnapshot],
        forceWorkTreeRoots: Set<String>,
        visitedRoots: Set<String>,
        remainingRepositoryCount: Int
    ) {
        guard !visitedRoots.contains(repository.workTreeRoot),
              remainingRepositoryCount > 0 else {
            return ([:], [:], [], visitedRoots, remainingRepositoryCount)
        }
        guard DispatchTime.now() < deadline else {
            return (
                [repository.workTreeRoot: [repository.gitDirectory, repository.commonDirectory]],
                [:],
                [],
                visitedRoots,
                remainingRepositoryCount
            )
        }
        var visitedRoots = visitedRoots
        visitedRoots.insert(repository.workTreeRoot)
        var remainingRepositoryCount = remainingRepositoryCount - 1
        var pathsByRepository: [String: [String]] = [:]
        var indexSnapshotsByRepository: [String: GitIndexSnapshot] = [:]
        var forceWorkTreeRoots: Set<String> = []

        let references = await gitReferenceSnapshotForConfig(
            repository: repository,
            deadline: deadline
        )
        guard references.checkedOutBranch != .unreadable else {
            // Keep the root metadata paths so a later HEAD/index/config event
            // can trigger a fresh plan instead of dropping the existing watcher.
            pathsByRepository[repository.workTreeRoot] = [
                repository.gitDirectory,
                repository.commonDirectory,
            ]
            return (pathsByRepository, indexSnapshotsByRepository, forceWorkTreeRoots, visitedRoots, remainingRepositoryCount)
        }
        let branchContext = GitConfigBranchContext.resolved(references.branchName)
        guard DispatchTime.now() < deadline else {
            return (pathsByRepository, indexSnapshotsByRepository, forceWorkTreeRoots, visitedRoots, remainingRepositoryCount)
        }
        pathsByRepository[repository.workTreeRoot] = GitConfigBranchTraversal(
            repository: repository,
            branchContext: branchContext,
            includeConditionalPathsForWatch: true,
            deadline: deadline
        ).watchPaths() + references.storageWatchPaths
        guard DispatchTime.now() < deadline else {
            return (pathsByRepository, indexSnapshotsByRepository, forceWorkTreeRoots, visitedRoots, remainingRepositoryCount)
        }

        if repositoryUsesSHA256ObjectIDs(
            repository: repository,
            deadline: deadline,
            branchContext: branchContext
        ) != false {
            forceWorkTreeRoots.insert(repository.workTreeRoot)
            return (pathsByRepository, indexSnapshotsByRepository, forceWorkTreeRoots, visitedRoots, remainingRepositoryCount)
        }

        let indexPath = joinedPath(root: repository.gitDirectory, relativePath: "index")
        guard let header = Self.gitIndexHeaderSummary(indexPath: indexPath),
              header.entryCount <= safetyConfiguration.trackedEventPathCount,
              header.fileByteCount <= Int64(safetyConfiguration.directIndexByteCount),
              let indexSnapshot = Self.gitIndexSnapshot(
                  indexURL: URL(fileURLWithPath: indexPath)
              ) else {
            return (pathsByRepository, indexSnapshotsByRepository, forceWorkTreeRoots, visitedRoots, remainingRepositoryCount)
        }
        // Reuse the root parse in the descriptor itself. Child snapshots are
        // only needed to discover their gitlinks and are intentionally released
        // after recursion so a large submodule tree cannot retain millions of
        // entries at once.
        if depth == 0 {
            indexSnapshotsByRepository[repository.workTreeRoot] = indexSnapshot
        }

        guard depth < safetyConfiguration.submoduleDepth else {
            return (
                pathsByRepository,
                indexSnapshotsByRepository,
                forceWorkTreeRoots,
                visitedRoots,
                remainingRepositoryCount
            )
        }

        let gitlinkMode: UInt32 = 0o160000
        for entry in indexSnapshot.entries where (entry.mode & 0o170000) == gitlinkMode {
            let gitlinkPath = joinedPath(
                root: repository.workTreeRoot,
                relativePath: entry.path
            )
            guard let submoduleRepository = Self.resolveGitRepository(containing: gitlinkPath),
                  submoduleRepository.workTreeRoot == gitlinkPath else {
                continue
            }
            let childResult = await collectBranchAwareConfigPaths(
                repository: submoduleRepository,
                depth: depth + 1,
                safetyConfiguration: safetyConfiguration,
                visitedRoots: visitedRoots,
                remainingRepositoryCount: remainingRepositoryCount,
                deadline: deadline
            )
            visitedRoots = childResult.visitedRoots
            remainingRepositoryCount = childResult.remainingRepositoryCount
            pathsByRepository.merge(childResult.paths, uniquingKeysWith: { _, new in new })
            indexSnapshotsByRepository.merge(
                childResult.indexSnapshots,
                uniquingKeysWith: { _, new in new }
            )
            forceWorkTreeRoots.formUnion(childResult.forceWorkTreeRoots)
        }
        return (
            pathsByRepository,
            indexSnapshotsByRepository,
            forceWorkTreeRoots,
            visitedRoots,
            remainingRepositoryCount
        )
    }
}
