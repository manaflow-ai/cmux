import Dispatch
import Foundation

extension GitMetadataService {
    /// Builds one bounded branch-aware config-path map for a repository tree.
    @concurrent
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
            deadline: deadline,
            configPathsByRepository: result.paths,
            metadataSentinelPathsByRepository: result.metadataSentinels,
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
        metadataSentinels: [String: [String]],
        indexSnapshots: [String: GitIndexSnapshot],
        forceWorkTreeRoots: Set<String>,
        visitedRoots: Set<String>,
        remainingRepositoryCount: Int
    ) {
        guard !visitedRoots.contains(repository.workTreeRoot),
              remainingRepositoryCount > 0 else {
            return ([:], [:], [:], [], visitedRoots, remainingRepositoryCount)
        }
        guard DispatchTime.now() < deadline else {
            return (
                [repository.workTreeRoot: conservativeRepositoryMetadataPaths(
                    repository: repository,
                    deadline: deadline
                )],
                [:],
                [:],
                [repository.workTreeRoot],
                visitedRoots,
                remainingRepositoryCount
            )
        }
        var visitedRoots = visitedRoots
        visitedRoots.insert(repository.workTreeRoot)
        var remainingRepositoryCount = remainingRepositoryCount - 1
        var pathsByRepository: [String: [String]] = [:]
        var metadataSentinelsByRepository: [String: [String]] = [:]
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
            forceWorkTreeRoots.insert(repository.workTreeRoot)
            return (pathsByRepository, metadataSentinelsByRepository, indexSnapshotsByRepository, forceWorkTreeRoots, visitedRoots, remainingRepositoryCount)
        }
        let branchContext = GitConfigBranchContext.resolved(references.branchName)
        guard DispatchTime.now() < deadline else {
            pathsByRepository[repository.workTreeRoot] = conservativeRepositoryMetadataPaths(
                repository: repository,
                deadline: deadline
            )
            forceWorkTreeRoots.insert(repository.workTreeRoot)
            return (pathsByRepository, metadataSentinelsByRepository, indexSnapshotsByRepository, forceWorkTreeRoots, visitedRoots, remainingRepositoryCount)
        }
        let configTraversal = await watchPathResult(
            repository: repository,
            branchContext: branchContext,
            deadline: deadline
        )
        pathsByRepository[repository.workTreeRoot] = configTraversal.paths
            + references.storageWatchPaths
        metadataSentinelsByRepository[repository.workTreeRoot] = configTraversal.metadataSentinelPaths
        if !configTraversal.isComplete {
            // An omitted include can live anywhere below the checkout (or its
            // linked Git directory). Reuse the existing conservative root
            // safety valve instead of recursively watching `.git` itself.
            forceWorkTreeRoots.insert(repository.workTreeRoot)
        }
        guard DispatchTime.now() < deadline else {
            forceWorkTreeRoots.insert(repository.workTreeRoot)
            return (pathsByRepository, metadataSentinelsByRepository, indexSnapshotsByRepository, forceWorkTreeRoots, visitedRoots, remainingRepositoryCount)
        }

        if configTraversal.objectFormatSHA256 != false {
            let fallback = await gitmodulesFallbackMetadataPathsBlocking(
                repository: repository,
                safetyConfiguration: safetyConfiguration,
                deadline: deadline,
                remainingRepositoryCount: remainingRepositoryCount
            )
            pathsByRepository[repository.workTreeRoot, default: []].append(contentsOf: fallback.paths)
            forceWorkTreeRoots.insert(repository.workTreeRoot)
            forceWorkTreeRoots.formUnion(fallback.forcedRoots)
            visitedRoots.formUnion(fallback.visitedRoots)
            remainingRepositoryCount = fallback.remainingRepositoryCount
            return (pathsByRepository, metadataSentinelsByRepository, indexSnapshotsByRepository, forceWorkTreeRoots, visitedRoots, remainingRepositoryCount)
        }

        let indexPath = joinedPath(root: repository.gitDirectory, relativePath: "index")
        let indexResult = await watchIndexSnapshot(
            indexPath: indexPath,
            deadline: deadline,
            maximumEntryCount: safetyConfiguration.trackedEventPathCount,
            maximumFileByteCount: safetyConfiguration.directIndexByteCount
        )
        guard let header = indexResult.header,
              header.entryCount <= safetyConfiguration.trackedEventPathCount,
              header.fileByteCount <= Int64(safetyConfiguration.directIndexByteCount),
              let indexSnapshot = indexResult.snapshot else {
            return (pathsByRepository, metadataSentinelsByRepository, indexSnapshotsByRepository, forceWorkTreeRoots, visitedRoots, remainingRepositoryCount)
        }
        // Reuse the parse in the descriptor itself. Child snapshots retain only
        // gitlink entries needed for nested watcher discovery, so a large
        // submodule index cannot retain millions of ordinary entries twice.
        if depth == 0 {
            indexSnapshotsByRepository[repository.workTreeRoot] = indexSnapshot
        } else {
            indexSnapshotsByRepository[repository.workTreeRoot] = GitIndexSnapshot(
                entries: indexSnapshot.entries.filter { ($0.mode & 0o170000) == 0o160000 },
                signature: indexSnapshot.signature,
                contentSignature: indexSnapshot.contentSignature
            )
        }

        guard depth < safetyConfiguration.submoduleDepth else {
            return (
                pathsByRepository,
                metadataSentinelsByRepository,
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
            metadataSentinelsByRepository.merge(childResult.metadataSentinels, uniquingKeysWith: { _, new in new })
            if childResult.paths[submoduleRepository.workTreeRoot] == nil {
                pathsByRepository[submoduleRepository.workTreeRoot] = conservativeRepositoryMetadataPaths(
                    repository: submoduleRepository,
                    deadline: deadline
                )
                forceWorkTreeRoots.insert(submoduleRepository.workTreeRoot)
            }
            indexSnapshotsByRepository.merge(
                childResult.indexSnapshots,
                uniquingKeysWith: { _, new in new }
            )
            forceWorkTreeRoots.formUnion(childResult.forceWorkTreeRoots)
        }
        return (
            pathsByRepository,
            metadataSentinelsByRepository,
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
        visitedRoots: inout Set<String>,
        forcedRoots: inout Set<String>
    ) -> [String] {
        guard depth < safetyConfiguration.submoduleDepth,
              remainingRepositoryCount > 0,
              !visitedRoots.contains(repository.workTreeRoot),
              deadline > DispatchTime.now(),
              !WorkspaceChangesCancellationSignal.isCurrentCancelled else { return [] }
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
            guard remainingRepositoryCount > 0,
                  deadline > DispatchTime.now(),
                  !WorkspaceChangesCancellationSignal.isCurrentCancelled else { break }
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
            paths.append(contentsOf: conservativeRepositoryMetadataPaths(
                repository: child,
                deadline: deadline
            ))
            forcedRoots.insert(child.workTreeRoot)
            paths.append(contentsOf: gitmodulesFallbackMetadataPaths(
                repository: child,
                depth: depth + 1,
                safetyConfiguration: safetyConfiguration,
                deadline: deadline,
                remainingRepositoryCount: &remainingRepositoryCount,
                visitedRoots: &visitedRoots,
                forcedRoots: &forcedRoots
            ))
        }
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    /// Runs the bounded config parser on the dedicated blocking-I/O lane.
    private nonisolated func watchPathResult(
        repository: ResolvedGitRepository,
        branchContext: GitConfigBranchContext,
        deadline: DispatchTime
    ) async -> GitConfigBranchTraversal.WatchPathResult {
        let traversal = GitConfigBranchTraversal(
            repository: repository,
            branchContext: branchContext,
            includeConditionalPathsForWatch: true,
            deadline: deadline
        )
        let cancellationSignal = WorkspaceChangesCancellationSignal(deadline: deadline)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.blockingStatusQueue.async {
                    let result = cancellationSignal.withCurrentBinding {
                        traversal.watchPathResult()
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellationSignal.cancel()
        }
    }

    /// Reads and parses one bounded index on the blocking-I/O lane.
    private nonisolated func watchIndexSnapshot(
        indexPath: String,
        deadline: DispatchTime,
        maximumEntryCount: Int,
        maximumFileByteCount: Int
    ) async -> (header: GitIndexHeaderSummary?, snapshot: GitIndexSnapshot?) {
        let cancellationSignal = WorkspaceChangesCancellationSignal(deadline: deadline)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.blockingStatusQueue.async {
                    let result = cancellationSignal.withCurrentBinding {
                        guard deadline > DispatchTime.now() else { return (nil, nil) }
                        let header = Self.gitIndexHeaderSummary(indexPath: indexPath)
                        let snapshot = header.flatMap { header in
                            guard header.entryCount <= maximumEntryCount,
                                  header.fileByteCount <= Int64(maximumFileByteCount) else {
                                return nil
                            }
                            return Self.gitIndexSnapshot(
                                indexURL: URL(fileURLWithPath: indexPath)
                            )
                        }
                        return (header, snapshot)
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellationSignal.cancel()
        }
    }

    /// Runs SHA-256 `.gitmodules` fallback discovery without occupying the
    /// cooperative executor and returns the consumed shared budget.
    private nonisolated func gitmodulesFallbackMetadataPathsBlocking(
        repository: ResolvedGitRepository,
        safetyConfiguration: GitMetadataSafetyConfiguration,
        deadline: DispatchTime,
        remainingRepositoryCount: Int
    ) async -> (
        paths: [String],
        forcedRoots: Set<String>,
        visitedRoots: Set<String>,
        remainingRepositoryCount: Int
    ) {
        let cancellationSignal = WorkspaceChangesCancellationSignal(deadline: deadline)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.blockingStatusQueue.async {
                    let result = cancellationSignal.withCurrentBinding {
                        var remaining = remainingRepositoryCount
                        var visited: Set<String> = []
                        var forced: Set<String> = []
                        let paths = gitmodulesFallbackMetadataPaths(
                            repository: repository,
                            depth: 0,
                            safetyConfiguration: safetyConfiguration,
                            deadline: deadline,
                            remainingRepositoryCount: &remaining,
                            visitedRoots: &visited,
                            forcedRoots: &forced
                        )
                        return (paths, forced, visited, remaining)
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellationSignal.cancel()
        }
    }

    /// Builds the final descriptor on the blocking-I/O lane. The static
    /// descriptor builder performs bounded index/stat reads and must not occupy
    /// a cooperative executor thread.
    nonisolated func watchDescriptorBlocking(
        for directory: String,
        safetyConfiguration: GitMetadataSafetyConfiguration,
        watchInputs: GitMetadataWatchInputs
    ) async -> GitWorkspaceMetadataWatchDescriptor? {
        let cancellationSignal = WorkspaceChangesCancellationSignal(deadline: watchInputs.deadline)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.blockingStatusQueue.async {
                    let descriptor = cancellationSignal.withCurrentBinding {
                        Self.workspaceGitMetadataWatchDescriptor(
                            for: directory,
                            safetyConfiguration: safetyConfiguration,
                            configPathsByRepository: watchInputs.configPathsByRepository,
                            metadataSentinelPathsByRepository: watchInputs.metadataSentinelPathsByRepository,
                            indexSnapshotsByRepository: watchInputs.indexSnapshotsByRepository,
                            deadline: watchInputs.deadline
                        )
                    }
                    continuation.resume(returning: descriptor)
                }
            }
        } onCancel: {
            cancellationSignal.cancel()
        }
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
            .rootConfigWatchURLs(repository: repository, deadline: deadline)
            .map(\.path)
    }
}
