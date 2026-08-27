import Foundation

extension GitMetadataService {
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
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GitWorkspaceMetadataWatchDescriptor? {
        guard let repository = resolveGitRepository(containing: directory) else {
            return nil
        }

        let repositoryConfigURLs = gitConfigURLs(
            repository: repository,
            environment: environment
        )
        let repositoryRoots = [
            repository.workTreeRoot,
            repository.gitDirectory,
            repository.commonDirectory
        ].map(nativeStandardizedPath)
        let sharedGlobalConfigURLs = repositoryConfigURLs.filter { configURL in
            let path = nativeStandardizedPath(configURL.path)
            return !repositoryRoots.contains { isSameOrInside(path, root: $0) }
        }
        let gitMetadataPaths = gitRepositoryMetadataWatchPaths(
            repository: repository,
            configURLsOverride: repositoryConfigURLs
        ) + gitlinkMetadataWatchPaths(
            repository: repository,
            safetyConfiguration: safetyConfiguration,
            environment: environment,
            sharedGlobalConfigURLs: sharedGlobalConfigURLs
        )
        let indexPath = joinedPath(root: repository.gitDirectory, relativePath: "index")
        let indexExists = FileManager.default.fileExists(atPath: indexPath)
        let header = gitIndexHeaderSummary(indexPath: indexPath)
        let declaredEntryCount = header?.entryCount ?? 0
        let exceedsTrackedPathBudget = header.map {
            $0.entryCount > safetyConfiguration.trackedEventPathCount
                || $0.fileByteCount > Int64(safetyConfiguration.directIndexByteCount)
        } ?? false
        let indexSnapshot: GitIndexSnapshot? = if header != nil, !exceedsTrackedPathBudget {
            gitIndexSnapshot(indexURL: URL(fileURLWithPath: indexPath))
        } else {
            nil
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
        let creationWatchPaths = missingExternalConfigWatchPaths(
            gitMetadataPaths: gitMetadataPaths,
            repository: repository
        )
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
            trackedEntryPaths: trackedEntryPaths,
            acceptsAllWorkTreeEvents: acceptsAllWorkTreeEvents,
            eventCoalescingInterval: eventCoalescingInterval,
            eventFilterIdentity: indexSnapshot?.contentSignature,
            degradation: degradation,
            creationWatchPaths: creationWatchPaths,
            creationWatchAllowedRoots: creationWatchAllowedRoots
        )
    }

    /// The metadata paths (`HEAD`, `index`, `refs`, `packed-refs`, every reachable
    /// `config`) for a single resolved repository.
    nonisolated static func gitRepositoryMetadataWatchPaths(
        repository: ResolvedGitRepository,
        configURLsOverride: [URL]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let configURLs = configURLsOverride ?? gitConfigURLs(
            repository: repository,
            environment: environment
        )
        [
            joinedPath(root: repository.gitDirectory, relativePath: "HEAD"),
            joinedPath(root: repository.gitDirectory, relativePath: "index"),
            joinedPath(root: repository.gitDirectory, relativePath: "refs"),
            joinedPath(root: repository.commonDirectory, relativePath: "refs"),
            joinedPath(root: repository.commonDirectory, relativePath: "packed-refs"),
        ] + configURLs.flatMap { configURL in
            [
                configURL.path,
                configURL.resolvingSymlinksInPath().path
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
            let normalized = nativeStandardizedPath(path)
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
    ) -> [String] {
        let repositoryRoots = [
            repository.workTreeRoot,
            repository.gitDirectory,
            repository.commonDirectory,
        ]
        var paths: [String] = []
        var seen: Set<String> = []
        for path in sortedUniqueNormalizedPaths(gitMetadataPaths) {
            guard path != "/",
                  !FileManager.default.fileExists(atPath: path),
                  !repositoryRoots.contains(where: { isSameOrInside(path, root: $0) }),
                  seen.insert(path).inserted else {
                continue
            }
            paths.append(path)
        }
        return paths
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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sharedGlobalConfigURLs: [URL]? = nil
    ) -> [String] {
        let sharedGlobalConfigURLs = sharedGlobalConfigURLs ?? {
            let configURLs = gitConfigURLs(
                repository: repository,
                safetyConfiguration: safetyConfiguration,
                environment: environment
            )
            let repositoryRoots = [
                repository.workTreeRoot,
                repository.gitDirectory,
                repository.commonDirectory
            ].map(nativeStandardizedPath)
            return configURLs.filter { configURL in
                let path = nativeStandardizedPath(configURL.path)
                return !repositoryRoots.contains { isSameOrInside(path, root: $0) }
            }
        }()
        var visitedWorkTreeRoots: Set<String> = [repository.workTreeRoot]
        return gitlinkMetadataWatchPaths(
            repository: repository,
            depth: 0,
            visitedWorkTreeRoots: &visitedWorkTreeRoots,
            safetyConfiguration: safetyConfiguration,
            environment: environment,
            sharedGlobalConfigURLs: sharedGlobalConfigURLs
        )
    }

    private nonisolated static func gitlinkMetadataWatchPaths(
        repository: ResolvedGitRepository,
        depth: Int,
        visitedWorkTreeRoots: inout Set<String>,
        safetyConfiguration: GitMetadataSafetyConfiguration,
        environment: [String: String],
        sharedGlobalConfigURLs: [URL]
    ) -> [String] {
        guard depth < safetyConfiguration.submoduleDepth else { return [] }
        let indexPath = joinedPath(root: repository.gitDirectory, relativePath: "index")
        guard let header = gitIndexHeaderSummary(indexPath: indexPath),
              header.entryCount <= safetyConfiguration.trackedEventPathCount,
              header.fileByteCount <= Int64(safetyConfiguration.directIndexByteCount) else {
            return []
        }
        let indexURL = URL(fileURLWithPath: indexPath)
        guard let indexSnapshot = gitIndexSnapshot(indexURL: indexURL) else {
            return []
        }

        let gitlinkMode: UInt32 = 0o160000
        var paths: [String] = []
        for entry in indexSnapshot.entries where (entry.mode & 0o170000) == gitlinkMode {
            let gitlinkPath = joinedPath(root: repository.workTreeRoot, relativePath: entry.path)
            guard visitedWorkTreeRoots.insert(gitlinkPath).inserted,
                  let submoduleRepository = resolveGitRepository(containing: gitlinkPath),
                  submoduleRepository.workTreeRoot == gitlinkPath else {
                continue
            }
            let localConfigURLs = gitConfigURLs(
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
            paths.append(
                contentsOf: gitRepositoryMetadataWatchPaths(
                    repository: submoduleRepository,
                    configURLsOverride: sharedGlobalConfigURLs + localConfigURLs
                )
            )
            paths.append(
                contentsOf: gitlinkMetadataWatchPaths(
                    repository: submoduleRepository,
                    depth: depth + 1,
                    visitedWorkTreeRoots: &visitedWorkTreeRoots,
                    safetyConfiguration: safetyConfiguration,
                    environment: environment,
                    sharedGlobalConfigURLs: sharedGlobalConfigURLs
                )
            )
        }
        return paths
    }
}
