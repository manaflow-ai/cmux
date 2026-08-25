import Foundation

extension GitMetadataService {
    /// Builds one bounded branch-aware config-path map for a repository tree.
    nonisolated func branchAwareConfigPathsByRepository(
        repository: ResolvedGitRepository,
        safetyConfiguration: GitMetadataSafetyConfiguration
    ) async -> [String: [String]] {
        await collectBranchAwareConfigPaths(
            repository: repository,
            depth: 0,
            safetyConfiguration: safetyConfiguration,
            visitedRoots: []
        )
    }

    private nonisolated func collectBranchAwareConfigPaths(
        repository: ResolvedGitRepository,
        depth: Int,
        safetyConfiguration: GitMetadataSafetyConfiguration,
        visitedRoots: Set<String>
    ) async -> [String: [String]] {
        guard !visitedRoots.contains(repository.workTreeRoot),
              depth < safetyConfiguration.submoduleDepth else {
            return [:]
        }
        var visitedRoots = visitedRoots
        visitedRoots.insert(repository.workTreeRoot)
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
            return pathsByRepository
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
            let childPaths = await collectBranchAwareConfigPaths(
                repository: submoduleRepository,
                depth: depth + 1,
                safetyConfiguration: safetyConfiguration,
                visitedRoots: visitedRoots
            )
            pathsByRepository.merge(childPaths, uniquingKeysWith: { _, new in new })
        }
        return pathsByRepository
    }
}
