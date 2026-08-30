import Dispatch
import Foundation

extension GitMetadataService {
    /// Computes the sorted, existing paths to watch for a directory's git
    /// metadata, including submodule gitlinks. Returns `nil` when `directory` is
    /// not inside a repository.
    nonisolated static func workspaceGitMetadataWatchedPaths(
        for directory: String,
        safetyConfiguration: GitMetadataSafetyConfiguration = GitMetadataSafetyConfiguration()
    ) -> [String]? {
        workspaceGitMetadataWatchDescriptor(
            for: directory,
            safetyConfiguration: safetyConfiguration
        )?.watchedPaths
    }

    /// Builds a bounded, Git-aware filesystem event plan. Normal repositories
    /// filter against tracked index paths, so ignored and untracked build trees
    /// schedule no dirty probe. Indexes above the path-filter budget retain an
    /// event source but impose a much longer throttle before bounded Git status.
    nonisolated static func workspaceGitMetadataWatchDescriptor(
        for directory: String,
        safetyConfiguration: GitMetadataSafetyConfiguration = GitMetadataSafetyConfiguration(),
        resolvedRepository: ResolvedGitRepository? = nil,
        configPathsByRepository: [String: [String]]? = nil,
        watchOnlyPathsByRepository: [String: [String]]? = nil,
        metadataSentinelPathsByRepository: [String: [String]]? = nil,
        indexSnapshotsByRepository: [String: GitIndexSnapshot]? = nil,
        deadline: DispatchTime? = nil
    ) -> GitWorkspaceMetadataWatchDescriptor? {
        guard let repository = resolvedRepository
            ?? resolveGitRepository(containing: directory, deadline: deadline) else {
            return nil
        }

        let normalizedMetadataSentinelPaths = Array(
            sortedUniqueNormalizedPaths(
                metadataSentinelPathsByRepository?.values.flatMap { $0 } ?? []
            ).prefix(256)
        )
        let metadataSentinelParentPaths = normalizedMetadataSentinelPaths.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path
        }
        let watchOnlyPaths = sortedUniqueNormalizedPaths(
            (watchOnlyPathsByRepository?.values.flatMap { $0 } ?? [])
                + metadataSentinelParentPaths
        )
        let watchOnlyPathSet = Set(watchOnlyPaths)
        let gitMetadataPaths = gitRepositoryMetadataWatchPaths(
            repository: repository,
            configPathsByRepository: configPathsByRepository
        ) + gitlinkMetadataWatchPaths(
            repository: repository,
            safetyConfiguration: safetyConfiguration,
            configPathsByRepository: configPathsByRepository,
            indexSnapshotsByRepository: indexSnapshotsByRepository,
            deadline: deadline
        )
        let indexPath = joinedPath(root: repository.gitDirectory, relativePath: "index")
        let indexReadResult = GitIndexDataReader().read(
            at: URL(fileURLWithPath: indexPath),
            maximumByteCount: safetyConfiguration.directIndexByteCount,
            deadline: deadline
        )
        let indexExists = indexReadResult.exists
        let header = indexReadResult.header
        let declaredEntryCount = header?.entryCount ?? 0
        let exceedsTrackedPathBudget = header.map {
            $0.entryCount > safetyConfiguration.trackedEventPathCount
                || $0.fileByteCount > Int64(safetyConfiguration.directIndexByteCount)
        } ?? false
        let indexSnapshot: GitIndexSnapshot?
        if header != nil, !exceedsTrackedPathBudget {
            let parser = GitIndexSnapshotParser()
            if let cached = indexSnapshotsByRepository?[repository.workTreeRoot],
               let data = indexReadResult.data,
               parser.signature(data: data) == cached.signature {
                indexSnapshot = cached
            } else {
                indexSnapshot = indexReadResult.data.flatMap {
                    parser.parse(data: $0, deadline: deadline)
                }
            }
        } else {
            indexSnapshot = nil
        }
        let acceptsAllWorkTreeEvents = exceedsTrackedPathBudget
        let includesWorkTreeRoot = acceptsAllWorkTreeEvents
            || indexSnapshot != nil
            || !indexExists
        let trackedEntryPaths: [String]
        if let indexSnapshot {
            trackedEntryPaths = sortedUniqueTrackedPaths(
                entries: indexSnapshot.entries,
                workTreeRoot: repository.workTreeRoot
            )
        } else {
            trackedEntryPaths = []
        }

        let degradation: GitWorkspaceMetadataWatchDegradation?
        if acceptsAllWorkTreeEvents, let header {
            degradation = .unfilteredWorkTreeEvents(
                entryCount: declaredEntryCount,
                trackedPathLimit: safetyConfiguration.trackedEventPathCount,
                indexByteCount: header.fileByteCount,
                indexByteLimit: safetyConfiguration.directIndexByteCount,
                throttleSeconds: safetyConfiguration.unfilteredWorkTreeEventThrottleSeconds
            )
        } else if indexExists, indexSnapshot == nil {
            degradation = .unreadableIndex
        } else if declaredEntryCount > safetyConfiguration.directFileStatusEntryCount {
            degradation = .boundedGitStatus(
                entryCount: declaredEntryCount,
                directEntryLimit: safetyConfiguration.directFileStatusEntryCount
            )
        } else {
            degradation = nil
        }

        let eventCoalescingInterval = acceptsAllWorkTreeEvents
            ? safetyConfiguration.unfilteredWorkTreeEventThrottle
            : safetyConfiguration.filteredWorkTreeEventThrottle
        let filterIdentity: String? = if normalizedMetadataSentinelPaths.isEmpty {
            indexSnapshot?.contentSignature
        } else {
            [indexSnapshot?.contentSignature, normalizedMetadataSentinelPaths.joined(separator: "\u{1f}")]
                .compactMap { $0 }
                .joined(separator: "\u{1e}")
        }
        let candidatePaths = (includesWorkTreeRoot ? [repository.workTreeRoot] : [])
            + gitMetadataPaths
            + watchOnlyPaths
        var watchedPaths: [String] = []
        var seen: Set<String> = []
        for path in candidatePaths {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            let normalized = String(decoding: standardized.utf8, as: UTF8.self)
            guard seen.insert(normalized).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory) else {
                continue
            }
            watchedPaths.append(normalized)
        }

        return GitWorkspaceMetadataWatchDescriptor(
            repositoryRoot: repository.workTreeRoot,
            watchedPaths: watchedPaths.sorted(),
            gitMetadataPaths: sortedUniqueNormalizedPaths(gitMetadataPaths),
            metadataSentinelPaths: normalizedMetadataSentinelPaths,
            trackedEntryPaths: trackedEntryPaths,
            acceptsAllWorkTreeEvents: acceptsAllWorkTreeEvents,
            eventCoalescingInterval: eventCoalescingInterval,
            eventFilterIdentity: filterIdentity,
            degradation: degradation
        )
    }

    /// The metadata paths (`HEAD`, `index`, `refs`, `packed-refs`, `reftable`,
    /// every reachable `config`) for a single resolved repository.
    nonisolated static func gitRepositoryMetadataWatchPaths(
        repository: ResolvedGitRepository,
        configPathsByRepository: [String: [String]]? = nil
    ) -> [String] {
        let configPaths = if let configPathsByRepository {
            configPathsByRepository[repository.workTreeRoot]
                ?? gitRootConfigURLs(repository: repository).map(\.path)
        } else {
            gitConfigURLs(repository: repository).map(\.path)
        }
        [
            joinedPath(root: repository.gitDirectory, relativePath: "HEAD"),
            joinedPath(root: repository.gitDirectory, relativePath: "index"),
            joinedPath(root: repository.gitDirectory, relativePath: "refs"),
            joinedPath(root: repository.gitDirectory, relativePath: "reftable"),
            joinedPath(root: repository.commonDirectory, relativePath: "refs"),
            joinedPath(root: repository.commonDirectory, relativePath: "packed-refs"),
            joinedPath(root: repository.commonDirectory, relativePath: "reftable"),
        ] + configPaths
    }

    private nonisolated static func sortedUniqueTrackedPaths(
        entries: [GitIndexEntryStat],
        workTreeRoot: String
    ) -> [String] {
        let sortedPaths = entries.map {
            joinedPath(root: workTreeRoot, relativePath: $0.path)
        }.sorted()
        var result: [String] = []
        result.reserveCapacity(sortedPaths.count)
        for path in sortedPaths where result.last != path {
            result.append(path)
        }
        return result
    }

    private nonisolated static func sortedUniqueNormalizedPaths(_ paths: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for path in paths {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            let normalized = String(decoding: standardized.utf8, as: UTF8.self)
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result.sorted()
    }

    /// The metadata paths contributed by gitlink (submodule) entries in the
    /// index, recursing into nested submodules so a checkout change at any
    /// depth wakes the watcher. Cycle-safe via the visited work-tree set.
    nonisolated static func gitlinkMetadataWatchPaths(
        repository: ResolvedGitRepository,
        safetyConfiguration: GitMetadataSafetyConfiguration,
        configPathsByRepository: [String: [String]]? = nil,
        indexSnapshotsByRepository: [String: GitIndexSnapshot]? = nil,
        deadline: DispatchTime? = nil
    ) -> [String] {
        var visitedWorkTreeRoots: Set<String> = [repository.workTreeRoot]
        return gitlinkMetadataWatchPaths(
            repository: repository,
            depth: 0,
            visitedWorkTreeRoots: &visitedWorkTreeRoots,
            safetyConfiguration: safetyConfiguration,
            configPathsByRepository: configPathsByRepository,
            indexSnapshotsByRepository: indexSnapshotsByRepository,
            deadline: deadline
        )
    }

    private nonisolated static func gitlinkMetadataWatchPaths(
        repository: ResolvedGitRepository,
        depth: Int,
        visitedWorkTreeRoots: inout Set<String>,
        safetyConfiguration: GitMetadataSafetyConfiguration,
        configPathsByRepository: [String: [String]]?,
        indexSnapshotsByRepository: [String: GitIndexSnapshot]?,
        deadline: DispatchTime?
    ) -> [String] {
        guard depth < safetyConfiguration.submoduleDepth else { return [] }
        if let deadline, deadline <= DispatchTime.now() { return [] }
        if let indexSnapshotsByRepository,
           indexSnapshotsByRepository[repository.workTreeRoot] == nil {
            // The aggregate planner did not finish this child before its
            // deadline/budget. Do not start a second index parse here.
            return []
        }
        let indexPath = joinedPath(root: repository.gitDirectory, relativePath: "index")
        guard let header = gitIndexHeaderSummary(indexPath: indexPath),
              header.entryCount <= safetyConfiguration.trackedEventPathCount,
              header.fileByteCount <= Int64(safetyConfiguration.directIndexByteCount) else {
            return []
        }
        let indexURL = URL(fileURLWithPath: indexPath)
        guard let indexSnapshot = indexSnapshotsByRepository?[repository.workTreeRoot]
            ?? gitIndexSnapshot(indexURL: indexURL) else {
            return []
        }

        let gitlinkMode: UInt32 = 0o160000
        var paths: [String] = []
        for entry in indexSnapshot.entries where (entry.mode & 0o170000) == gitlinkMode {
            let gitlinkPath = joinedPath(root: repository.workTreeRoot, relativePath: entry.path)
            guard visitedWorkTreeRoots.insert(gitlinkPath).inserted,
                  let submoduleRepository = resolveGitRepository(
                      containing: gitlinkPath,
                      deadline: deadline
                  ),
                  submoduleRepository.workTreeRoot == gitlinkPath else {
                continue
            }
            // A missing child entry means the aggregate planner exhausted its
            // deadline/budget. Use only bounded root sentinels here; starting a
            // fresh include walk would escape that aggregate bound.
            let submoduleConfigPaths = configPathsByRepository?[submoduleRepository.workTreeRoot]
                ?? [
                    joinedPath(root: submoduleRepository.commonDirectory, relativePath: "config"),
                    joinedPath(root: submoduleRepository.gitDirectory, relativePath: "config"),
                    joinedPath(root: submoduleRepository.gitDirectory, relativePath: "config.worktree"),
                ]
            paths.append(contentsOf: gitRepositoryMetadataWatchPaths(
                repository: submoduleRepository,
                configPathsByRepository: [submoduleRepository.workTreeRoot: submoduleConfigPaths]
            ))
            paths.append(
                contentsOf: gitlinkMetadataWatchPaths(
                    repository: submoduleRepository,
                    depth: depth + 1,
                    visitedWorkTreeRoots: &visitedWorkTreeRoots,
                    safetyConfiguration: safetyConfiguration,
                    configPathsByRepository: configPathsByRepository,
                    indexSnapshotsByRepository: indexSnapshotsByRepository,
                    deadline: deadline
                )
            )
        }
        return paths
    }
}
