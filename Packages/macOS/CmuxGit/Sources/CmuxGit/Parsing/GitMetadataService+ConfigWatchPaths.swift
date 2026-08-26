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
                [repository.workTreeRoot: conservativeRepositoryMetadataPaths(
                    repository: repository,
                    deadline: deadline
                )],
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
            pathsByRepository[repository.workTreeRoot] = conservativeRepositoryMetadataPaths(
                repository: repository,
                deadline: deadline
            )
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
            var fallbackRemainingRepositoryCount = remainingRepositoryCount
            var fallbackVisitedRoots: Set<String> = []
            pathsByRepository[repository.workTreeRoot, default: []].append(contentsOf:
                gitmodulesFallbackMetadataPaths(
                    repository: repository,
                    depth: 0,
                    safetyConfiguration: safetyConfiguration,
                    deadline: deadline,
                    remainingRepositoryCount: &fallbackRemainingRepositoryCount,
                    visitedRoots: &fallbackVisitedRoots
                )
            )
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
            if depth + 1 >= safetyConfiguration.submoduleDepth
                || remainingRepositoryCount <= 1
                || DispatchTime.now() >= deadline {
                forceWorkTreeRoots.insert(repository.workTreeRoot)
                break
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
            if childResult.paths[submoduleRepository.workTreeRoot] == nil {
                pathsByRepository[submoduleRepository.workTreeRoot] = conservativeRepositoryMetadataPaths(
                    repository: submoduleRepository,
                    deadline: deadline
                )
            }
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

    /// Discovers direct submodule metadata roots when the SHA-1 index parser is
    /// unavailable (for example in a SHA-256 repository).
    private nonisolated func gitmodulesFallbackMetadataPaths(
        repository: ResolvedGitRepository,
        depth: Int,
        safetyConfiguration: GitMetadataSafetyConfiguration,
        deadline: DispatchTime,
        remainingRepositoryCount: inout Int,
        visitedRoots: inout Set<String>
    ) -> [String] {
        guard depth < safetyConfiguration.submoduleDepth,
              remainingRepositoryCount > 0,
              !visitedRoots.contains(repository.workTreeRoot),
              deadline > DispatchTime.now() else { return [] }
        remainingRepositoryCount -= 1
        visitedRoots.insert(repository.workTreeRoot)
        let gitmodulesURL = URL(fileURLWithPath: repository.workTreeRoot)
            .appendingPathComponent(".gitmodules")
        let reader = GitConfigFileReader()
        guard case .contents(let contents, consumedByteCount: _) = reader.read(
            at: gitmodulesURL,
            maximumByteCount: GitConfigFileReader.defaultMaximumByteCount,
            deadline: deadline
        ) else {
            return []
        }
        var paths: [String] = [gitmodulesURL.path]
        var inSubmoduleSection = false
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            guard remainingRepositoryCount > 0, deadline > DispatchTime.now() else { break }
            let line = GitMetadataService.gitConfigLineRemovingInlineComment(String(rawLine))
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inSubmoduleSection = line.lowercased().hasPrefix("[submodule ")
                continue
            }
            guard inSubmoduleSection else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[0].lowercased() == "path" else { continue }
            let relativePath = GitMetadataService.gitConfigUnquotedValue(parts[1])
            guard !relativePath.isEmpty,
                  !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains("..") else { continue }
            let rootURL = URL(fileURLWithPath: repository.workTreeRoot)
            let childURL = rootURL.appendingPathComponent(relativePath).standardizedFileURL
            let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            let canonicalChild = childURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonicalChild == canonicalRoot
                    || canonicalChild.hasPrefix(canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/") else {
                continue
            }
            let childPath = childURL.path
            guard let child = Self.resolveGitRepository(containing: childPath),
                  child.workTreeRoot == childPath,
                  !visitedRoots.contains(child.workTreeRoot) else { continue }
            paths.append(contentsOf: [
                child.workTreeRoot,
            ] + conservativeRepositoryMetadataPaths(
                repository: child,
                deadline: deadline
            ))
            paths.append(contentsOf: gitmodulesFallbackMetadataPaths(
                repository: child,
                depth: depth + 1,
                safetyConfiguration: safetyConfiguration,
                deadline: deadline,
                remainingRepositoryCount: &remainingRepositoryCount,
                visitedRoots: &visitedRoots
            ))
        }
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    private nonisolated func conservativeRepositoryMetadataPaths(
        repository: ResolvedGitRepository,
        deadline: DispatchTime
    ) -> [String] {
        [
            joinedPath(root: repository.gitDirectory, relativePath: "HEAD"),
            joinedPath(root: repository.gitDirectory, relativePath: "index"),
            joinedPath(root: repository.gitDirectory, relativePath: "refs"),
            joinedPath(root: repository.gitDirectory, relativePath: "reftable"),
            joinedPath(root: repository.commonDirectory, relativePath: "refs"),
            joinedPath(root: repository.commonDirectory, relativePath: "packed-refs"),
            joinedPath(root: repository.commonDirectory, relativePath: "reftable"),
        ] + GitWorktreeConfigEnablementReader()
            .rootConfigURLs(repository: repository, deadline: deadline)
            .map(\.path)
    }
}
