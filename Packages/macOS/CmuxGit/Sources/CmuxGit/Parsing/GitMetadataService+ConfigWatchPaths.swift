import Foundation

extension GitMetadataService {
    /// Builds one bounded branch-aware config-path map for a repository tree.
    nonisolated func branchAwareConfigPathsByRepository(
        repository: ResolvedGitRepository,
        safetyConfiguration: GitMetadataSafetyConfiguration
    ) async -> [String: [String]] {
        let result = await collectBranchAwareConfigPaths(
            repository: repository,
            depth: 0,
            safetyConfiguration: safetyConfiguration,
            visitedRoots: [],
            remainingRepositoryCount: 64
        )
        return result.paths
    }

    private nonisolated func collectBranchAwareConfigPaths(
        repository: ResolvedGitRepository,
        depth: Int,
        safetyConfiguration: GitMetadataSafetyConfiguration,
        visitedRoots: Set<String>,
        remainingRepositoryCount: Int
    ) async -> (paths: [String: [String]], visitedRoots: Set<String>, remainingRepositoryCount: Int) {
        guard !visitedRoots.contains(repository.workTreeRoot),
              remainingRepositoryCount > 0 else {
            return ([:], visitedRoots, remainingRepositoryCount)
        }
        var visitedRoots = visitedRoots
        visitedRoots.insert(repository.workTreeRoot)
        var remainingRepositoryCount = remainingRepositoryCount - 1
        var pathsByRepository: [String: [String]] = [:]

        let branchContext = await gitReferenceBranchContext(repository: repository)
        pathsByRepository[repository.workTreeRoot] = GitConfigBranchTraversal(
            repository: repository,
            branchContext: branchContext
        ).watchPaths()

        let indexPath = joinedPath(root: repository.gitDirectory, relativePath: "index")
        guard let header = Self.gitIndexHeaderSummary(indexPath: indexPath),
              header.entryCount <= safetyConfiguration.trackedEventPathCount,
              header.fileByteCount <= Int64(safetyConfiguration.directIndexByteCount),
              let indexSnapshot = Self.gitIndexSnapshot(
                  indexURL: URL(fileURLWithPath: indexPath)
              ) else {
            return (pathsByRepository, visitedRoots, remainingRepositoryCount)
        }

        guard depth < safetyConfiguration.submoduleDepth else {
            return (pathsByRepository, visitedRoots, remainingRepositoryCount)
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
                remainingRepositoryCount: remainingRepositoryCount
            )
            visitedRoots = childResult.visitedRoots
            remainingRepositoryCount = childResult.remainingRepositoryCount
            pathsByRepository.merge(childResult.paths, uniquingKeysWith: { _, new in new })
        }
        return (pathsByRepository, visitedRoots, remainingRepositoryCount)
    }
}
