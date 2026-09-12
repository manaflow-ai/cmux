import Dispatch
import Foundation

extension GitMetadataService {
    private static let maximumGitMetadataWatchPathCount = 4_096
    private static let maximumCreationWatchPathCount = 512

    /// Computes the sorted, existing paths to watch for a directory's git
    /// metadata, including submodule gitlinks. Returns `nil` when `directory` is
    /// not inside a repository.
    nonisolated static func workspaceGitMetadataWatchedPaths(
        for directory: String,
        safetyConfiguration: GitMetadataSafetyConfiguration = GitMetadataSafetyConfiguration(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String]? {
        workspaceGitMetadataWatchDescriptor(
            for: directory,
            safetyConfiguration: safetyConfiguration,
            environment: environment
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
        deadline: DispatchTime? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
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
        let repositoryConfigSnapshot = gitRemoteConfigSnapshot(
            repository: repository,
            safetyConfiguration: safetyConfiguration,
            environment: environment
        )
        let repositoryConfigURLs = configPathsByRepository?[repository.workTreeRoot]
            .map { $0.map(URL.init(fileURLWithPath:)) }
            ?? (repositoryConfigSnapshot.configURLs + repositoryConfigSnapshot.watchFallbackURLs)
        let sharedGlobalConfigURLs = repositoryConfigSnapshot.globalConfigURLs
        let rawGitMetadataPaths = gitRepositoryMetadataWatchPaths(
            repository: repository,
            configPathsByRepository: configPathsByRepository,
            configURLsOverride: repositoryConfigURLs,
            environment: environment
        ) + gitlinkMetadataWatchPaths(
            repository: repository,
            safetyConfiguration: safetyConfiguration,
            configPathsByRepository: configPathsByRepository,
            indexSnapshotsByRepository: indexSnapshotsByRepository,
            deadline: deadline,
            environment: environment,
            sharedGlobalConfigURLs: sharedGlobalConfigURLs
        )
        let gitMetadataPaths = Array(
            rawGitMetadataPaths.prefix(Self.maximumGitMetadataWatchPathCount)
        )
        let gitMetadataPathsAreComplete =
            rawGitMetadataPaths.count <= Self.maximumGitMetadataWatchPathCount
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
                indexSnapshot = indexReadResult.data.flatMap { parser.parse(data: $0, deadline: deadline) }
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
        let creationWatchPlan = missingExternalConfigWatchPaths(
            gitMetadataPaths: gitMetadataPaths,
            repository: repository
        )
        let creationWatchPaths = creationWatchPlan.paths
        let homeDirectory: URL
        if let configuredHome = environment["HOME"], !configuredHome.isEmpty {
            homeDirectory = URL(fileURLWithPath: configuredHome).standardizedFileURL
        } else {
            homeDirectory = GitMetadataService.processHomeDirectory
        }
        let xdgConfigHome: URL
        if let configuredXDGHome = environment["XDG_CONFIG_HOME"],
           !configuredXDGHome.isEmpty {
            xdgConfigHome = URL(fileURLWithPath: configuredXDGHome)
        } else {
            xdgConfigHome = homeDirectory.appendingPathComponent(".config", isDirectory: true)
        }
        let creationWatchAllowedRoots = [
            homeDirectory.resolvingSymlinksInPath().path,
            xdgConfigHome.resolvingSymlinksInPath().path,
            URL(fileURLWithPath: repository.workTreeRoot)
                .resolvingSymlinksInPath()
                .path,
            URL(fileURLWithPath: repository.gitDirectory)
                .resolvingSymlinksInPath()
                .path,
            URL(fileURLWithPath: repository.commonDirectory)
                .resolvingSymlinksInPath()
                .path,
        ]
        let creationWatchPathSet = Set(creationWatchPaths)
        let recursiveMetadataPaths = gitMetadataPaths.filter {
            !creationWatchPathSet.contains(nativeStandardizedPath($0))
        }
        let candidatePaths = (includesWorkTreeRoot ? [repository.workTreeRoot] : [])
            + recursiveMetadataPaths
            + watchOnlyPaths
        var watchedPaths: [String] = []
        var seen: Set<String> = []
        for path in candidatePaths {
            let normalized = nativeStandardizedPath(path)
            guard let watchRoot = existingWatchRoot(
                for: normalized,
                repository: repository
            ),
                  seen.insert(watchRoot).inserted else {
                continue
            }
            watchedPaths.append(watchRoot)
        }

        return GitWorkspaceMetadataWatchDescriptor(
            repositoryRoot: repository.workTreeRoot,
            watchedPaths: watchedPaths.sorted(),
            gitMetadataPaths: filteredMetadataWatchPaths(
                gitMetadataPaths,
                repository: repository
            ),
            metadataSentinelPaths: normalizedMetadataSentinelPaths,
            trackedEntryPaths: trackedEntryPaths,
            forcedWorkTreeRoots: [],
            acceptsAllWorkTreeEvents: acceptsAllWorkTreeEvents,
            eventCoalescingInterval: eventCoalescingInterval,
            eventFilterIdentity: filterIdentity,
            degradation: degradation,
            creationWatchPaths: creationWatchPaths,
            creationWatchAllowedRoots: creationWatchAllowedRoots,
            creationWatchPathsAreComplete:
                gitMetadataPathsAreComplete && creationWatchPlan.isComplete
        )
    }

    /// The metadata paths (`HEAD`, `index`, `refs`, `packed-refs`, `reftable`,
    /// every reachable `config`) for a single resolved repository.
    nonisolated static func gitRepositoryMetadataWatchPaths(
        repository: ResolvedGitRepository,
        configPathsByRepository: [String: [String]]? = nil,
        configURLsOverride: [URL]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let configPaths: [String]
        if let configURLsOverride {
            configPaths = configURLsOverride.map(\.path)
        } else if let configPathsByRepository {
            configPaths = configPathsByRepository[repository.workTreeRoot]
                ?? gitRootConfigURLs(repository: repository, environment: environment).map(\.path)
        } else {
            configPaths = gitConfigURLs(repository: repository, environment: environment).map(\.path)
        }
        return [
            joinedPath(root: repository.gitDirectory, relativePath: "HEAD"),
            joinedPath(root: repository.gitDirectory, relativePath: "index"),
            joinedPath(root: repository.gitDirectory, relativePath: "refs"),
            joinedPath(root: repository.gitDirectory, relativePath: "reftable"),
            joinedPath(root: repository.commonDirectory, relativePath: "refs"),
            joinedPath(root: repository.commonDirectory, relativePath: "packed-refs"),
            joinedPath(root: repository.commonDirectory, relativePath: "reftable"),
        ] + configPaths.flatMap { path in
            [
                path,
                URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            ].filter(isWatchableConfigDependency)
        }
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

    /// Returns an existing path to watch, falling back to a bounded existing
    /// parent when a declared config/include path has not been created yet.
    private nonisolated static func existingWatchRoot(
        for path: String,
        repository: ResolvedGitRepository
    ) -> String? {
        var candidate = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                let resolved = nativeStandardizedPath(
                    candidate.resolvingSymlinksInPath().path
                )
                guard isAllowedDirectoryWatchRoot(resolved, repository: repository) else {
                    return nil
                }
                return nativeStandardizedPath(candidate.path)
            }
            return nativeStandardizedPath(candidate.path)
        }

        // A missing path outside the repository gets at most its immediate,
        // already-existing parent. Walking farther upward can turn a missing
        // global config file (for example ~/.config/git/config) into a recursive
        // watch of an unrelated user directory.
        let normalizedPath = nativeStandardizedPath(path)
        guard !isSameOrInside(normalizedPath, root: repository.workTreeRoot),
              !isSameOrInside(normalizedPath, root: repository.gitDirectory),
              !isSameOrInside(normalizedPath, root: repository.commonDirectory) else {
            return existingRepositoryScopedWatchRoot(
                for: candidate,
                repository: repository
            )
        }
        let parent = candidate.deletingLastPathComponent()
        guard parent.path != candidate.path,
              FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        let normalizedParent = nativeStandardizedPath(parent.path)
        guard isAllowedDirectoryWatchRoot(normalizedParent, repository: repository) else {
            return nil
        }
        return normalizedParent
    }

    private nonisolated static func existingRepositoryScopedWatchRoot(
        for initialCandidate: URL,
        repository: ResolvedGitRepository
    ) -> String? {
        var candidate = initialCandidate
        var isDirectory: ObjCBool = false
        while true {
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                let normalized = nativeStandardizedPath(candidate.path)
                guard isDirectory.boolValue,
                      isAllowedDirectoryWatchRoot(normalized, repository: repository) else {
                    return nil
                }
                return normalized
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    private nonisolated static func isSameOrInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private nonisolated static func isAllowedDirectoryWatchRoot(
        _ path: String,
        repository: ResolvedGitRepository
    ) -> Bool {
        let normalized = nativeStandardizedPath(path)
        guard normalized != "/" else { return false }
        let logicalRepositoryRoots = [
            repository.workTreeRoot,
            repository.gitDirectory,
            repository.commonDirectory
        ].map(nativeStandardizedPath)
        let resolved = nativeStandardizedPath(
            URL(fileURLWithPath: normalized).resolvingSymlinksInPath().path
        )
        let resolvedRepositoryRoots = logicalRepositoryRoots.map {
            nativeStandardizedPath(
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            )
        }
        let home = nativeStandardizedPath(
            FileManager.default.homeDirectoryForCurrentUser.path
        )
        let resolvedHome = nativeStandardizedPath(
            URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        )
        return resolvedRepositoryRoots.contains { isSameOrInside(resolved, root: $0) }
            || (resolved != resolvedHome && isSameOrInside(resolved, root: resolvedHome))
    }

    private nonisolated static func filteredMetadataWatchPaths(
        _ paths: [String],
        repository: ResolvedGitRepository
    ) -> [String] {
        sortedUniqueNormalizedPaths(paths).filter { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return true
            }
            guard isDirectory.boolValue else { return true }
            let resolved = nativeStandardizedPath(
                URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            )
            return isAllowedDirectoryWatchRoot(resolved, repository: repository)
        }
    }

    private nonisolated static func isWatchableConfigDependency(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return true
        }
        return !isDirectory.boolValue
    }

    private nonisolated static func missingExternalConfigWatchPaths(
        gitMetadataPaths: [String],
        repository: ResolvedGitRepository
    ) -> (paths: [String], isComplete: Bool) {
        let repositoryRoots = [
            repository.workTreeRoot,
            repository.gitDirectory,
            repository.commonDirectory,
        ]
        var paths: [String] = []
        var seen: Set<String> = []
        var isComplete = true
        for rawPath in gitMetadataPaths {
            let path = nativeStandardizedPath(rawPath)
            guard path != "/",
                  !FileManager.default.fileExists(atPath: path),
                  !repositoryRoots.contains(where: { isSameOrInside(path, root: $0) }),
                  seen.insert(path).inserted else {
                continue
            }
            guard paths.count < Self.maximumCreationWatchPathCount else {
                isComplete = false
                break
            }
            paths.append(path)
        }
        return (paths.sorted(), isComplete)
    }

    /// Standardizes once outside event loops and copies Foundation-backed path
    /// strings into native Swift UTF-8 storage for fast comparisons.
    private nonisolated static func nativeStandardizedPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return String(decoding: standardized.utf8, as: UTF8.self)
    }
    /// The metadata paths contributed by gitlink (submodule) entries in the
    /// index, recursing into nested submodules so a checkout change at any
    /// depth wakes the watcher. Cycle-safe via the visited work-tree set.
    nonisolated static func gitlinkMetadataWatchPaths(
        repository: ResolvedGitRepository,
        safetyConfiguration: GitMetadataSafetyConfiguration,
        configPathsByRepository: [String: [String]]? = nil,
        indexSnapshotsByRepository: [String: GitIndexSnapshot]? = nil,
        deadline: DispatchTime? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sharedGlobalConfigURLs: [URL]? = nil
    ) -> [String] {
        let sharedGlobalConfigURLs = sharedGlobalConfigURLs ?? {
            let configSnapshot = gitRemoteConfigSnapshot(
                repository: repository,
                safetyConfiguration: safetyConfiguration,
                environment: environment
            )
            return configSnapshot.globalConfigURLs
        }()
        var visitedWorkTreeRoots: Set<String> = [repository.workTreeRoot]
        return gitlinkMetadataWatchPaths(
            repository: repository,
            depth: 0,
            visitedWorkTreeRoots: &visitedWorkTreeRoots,
            safetyConfiguration: safetyConfiguration,
            configPathsByRepository: configPathsByRepository,
            indexSnapshotsByRepository: indexSnapshotsByRepository,
            deadline: deadline,
            environment: environment,
            sharedGlobalConfigURLs: sharedGlobalConfigURLs
        )
    }

    private nonisolated static func gitlinkMetadataWatchPaths(
        repository: ResolvedGitRepository,
        depth: Int,
        visitedWorkTreeRoots: inout Set<String>,
        safetyConfiguration: GitMetadataSafetyConfiguration,
        configPathsByRepository: [String: [String]]?,
        indexSnapshotsByRepository: [String: GitIndexSnapshot]?,
        deadline: DispatchTime?,
        environment: [String: String],
        sharedGlobalConfigURLs: [URL]
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
            let localConfigSnapshot = gitRemoteConfigSnapshot(
                repository: submoduleRepository,
                safetyConfiguration: safetyConfiguration,
                configRootURLs: [
                    URL(fileURLWithPath: submoduleRepository.commonDirectory)
                        .appendingPathComponent("config"),
                    URL(fileURLWithPath: submoduleRepository.gitDirectory)
                        .appendingPathComponent("config"),
                ],
                environment: environment
            )
            let localConfigURLs = configPathsByRepository?[submoduleRepository.workTreeRoot]
                .map { $0.map(URL.init(fileURLWithPath:)) }
                ?? (localConfigSnapshot.configURLs + localConfigSnapshot.watchFallbackURLs)
            paths.append(
                contentsOf: gitRepositoryMetadataWatchPaths(
                    repository: submoduleRepository,
                    configPathsByRepository: configPathsByRepository,
                    configURLsOverride: sharedGlobalConfigURLs + localConfigURLs,
                    environment: environment
                )
            )
            paths.append(
                contentsOf: gitlinkMetadataWatchPaths(
                    repository: submoduleRepository,
                    depth: depth + 1,
                    visitedWorkTreeRoots: &visitedWorkTreeRoots,
                    safetyConfiguration: safetyConfiguration,
                    configPathsByRepository: configPathsByRepository,
                    indexSnapshotsByRepository: indexSnapshotsByRepository,
                    deadline: deadline,
                    environment: environment,
                    sharedGlobalConfigURLs: sharedGlobalConfigURLs
                )
            )
        }
        return paths
    }
}
