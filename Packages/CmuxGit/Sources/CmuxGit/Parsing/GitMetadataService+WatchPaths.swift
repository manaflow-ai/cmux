import Foundation

/// The filesystem-watch plan for keeping a workspace's sidebar git metadata
/// fresh without treating every event under a large work tree as meaningful.
public struct GitWorkspaceMetadataWatchDescriptor: Equatable, Sendable {
    /// Existing absolute paths that should be passed to the filesystem watcher.
    public let watchedPaths: [String]

    /// Absolute git metadata paths whose changes can affect branch, index, refs,
    /// config, submodule gitlink state, or remote slug resolution.
    public let gitMetadataPaths: [String]

    /// Absolute tracked working-tree entry paths from the root repository index.
    ///
    /// Events outside these paths cannot change the dirty bit. The list is sorted
    /// so relevance checks can binary-search instead of scanning the full index
    /// on every filesystem event.
    public let trackedEntryPaths: [String]

    public init(watchedPaths: [String], gitMetadataPaths: [String], trackedEntryPaths: [String]) {
        self.watchedPaths = watchedPaths
        self.gitMetadataPaths = gitMetadataPaths
        self.trackedEntryPaths = trackedEntryPaths
    }

    /// Whether a coalesced filesystem event can change the corresponding
    /// ``GitWorkspaceMetadata`` snapshot.
    ///
    /// Empty path detail is treated as relevant so callers stay correct on OS
    /// events that do not include file-level paths.
    public func containsRelevantChange(paths: [String]) -> Bool {
        guard !paths.isEmpty else { return true }
        return paths.contains { containsRelevantChange(path: $0) }
    }

    public func containsRelevantChange(path: String) -> Bool {
        let normalizedPath = Self.normalizedPath(path)
        if containsRelevantChange(normalizedPath: normalizedPath) {
            return true
        }
        if let alternatePath = Self.alternateVarPath(for: normalizedPath) {
            return containsRelevantChange(normalizedPath: alternatePath)
        }
        return false
    }

    private func containsRelevantChange(normalizedPath: String) -> Bool {
        if gitMetadataPaths.contains(where: { Self.path(normalizedPath, isSameOrInside: $0) }) {
            return true
        }
        return containsTrackedEntryChange(path: normalizedPath)
    }

    private func containsTrackedEntryChange(path: String) -> Bool {
        guard !trackedEntryPaths.isEmpty else { return false }
        let index = lowerBound(for: path)
        if index < trackedEntryPaths.endIndex, trackedEntryPaths[index] == path {
            return true
        }
        let directoryPrefix = path.hasSuffix("/") ? path : path + "/"
        let prefixIndex = lowerBound(for: directoryPrefix)
        return prefixIndex < trackedEntryPaths.endIndex
            && trackedEntryPaths[prefixIndex].hasPrefix(directoryPrefix)
    }

    private func lowerBound(for value: String) -> Int {
        var low = trackedEntryPaths.startIndex
        var high = trackedEntryPaths.endIndex
        while low < high {
            let mid = low + (high - low) / 2
            if trackedEntryPaths[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func path(_ path: String, isSameOrInside root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func normalizedPath(_ path: String) -> String {
        if !path.contains("//"),
           !path.contains("/./"),
           !path.contains("/../"),
           !path.hasSuffix("/."),
           !path.hasSuffix("/..") {
            return path
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func alternateVarPath(for path: String) -> String? {
        if path == "/var" {
            return "/private/var"
        }
        if path.hasPrefix("/var/") {
            return "/private" + path
        }
        if path == "/private/var" {
            return "/var"
        }
        if path.hasPrefix("/private/var/") {
            return String(path.dropFirst("/private".count))
        }
        return nil
    }
}

extension GitMetadataService {
    /// Computes the sorted, existing paths to watch for a directory's git
    /// metadata, including submodule gitlinks. Returns `nil` when `directory` is
    /// not inside a repository.
    nonisolated static func workspaceGitMetadataWatchedPaths(
        for directory: String
    ) -> [String]? {
        workspaceGitMetadataWatchDescriptor(for: directory)?.watchedPaths
    }

    /// Computes the watcher descriptor for a directory's git metadata.
    nonisolated static func workspaceGitMetadataWatchDescriptor(
        for directory: String
    ) -> GitWorkspaceMetadataWatchDescriptor? {
        guard let repository = resolveGitRepository(containing: directory) else {
            return nil
        }
        let gitMetadataPaths = gitRepositoryMetadataWatchPaths(repository: repository)
            + gitlinkMetadataWatchPaths(repository: repository)
        let trackedEntryPaths = gitTrackedEntryWatchPaths(repository: repository)

        let candidatePaths = [
            repository.workTreeRoot,
        ] + gitMetadataPaths
        var watchedPaths: [String] = []
        var seen: Set<String> = []
        for path in candidatePaths {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory) else {
                continue
            }
            watchedPaths.append(normalized)
        }

        return GitWorkspaceMetadataWatchDescriptor(
            watchedPaths: watchedPaths.sorted(),
            gitMetadataPaths: sortedUniqueNormalizedPaths(gitMetadataPaths),
            trackedEntryPaths: trackedEntryPaths
        )
    }

    /// The metadata paths (`HEAD`, `index`, `refs`, `packed-refs`, every reachable
    /// `config`) for a single resolved repository.
    nonisolated static func gitRepositoryMetadataWatchPaths(
        repository: ResolvedGitRepository
    ) -> [String] {
        [
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD").path,
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index").path,
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("refs").path,
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("refs").path,
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("packed-refs").path,
        ] + gitConfigURLs(repository: repository).map(\.path)
    }

    /// The metadata paths contributed by gitlink (submodule) entries in the
    /// index, recursing into nested submodules so a checkout change at any
    /// depth wakes the watcher. Cycle-safe via the visited work-tree set.
    nonisolated static func gitlinkMetadataWatchPaths(
        repository: ResolvedGitRepository
    ) -> [String] {
        var visitedWorkTreeRoots: Set<String> = [repository.workTreeRoot]
        return gitlinkMetadataWatchPaths(repository: repository, visitedWorkTreeRoots: &visitedWorkTreeRoots)
    }

    private nonisolated static func gitTrackedEntryWatchPaths(
        repository: ResolvedGitRepository
    ) -> [String] {
        let indexURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index")
        guard let indexSnapshot = gitIndexSnapshot(indexURL: indexURL) else {
            return []
        }
        return sortedUniqueNormalizedPaths(indexSnapshot.entries.map { entry in
            URL(fileURLWithPath: repository.workTreeRoot)
                .appendingPathComponent(entry.path)
                .standardizedFileURL
                .path
        })
    }

    private nonisolated static func sortedUniqueNormalizedPaths(_ paths: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for path in paths {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result.sorted()
    }

    private nonisolated static func gitlinkMetadataWatchPaths(
        repository: ResolvedGitRepository,
        visitedWorkTreeRoots: inout Set<String>
    ) -> [String] {
        let indexURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index")
        guard let indexSnapshot = gitIndexSnapshot(indexURL: indexURL) else {
            return []
        }

        let gitlinkMode: UInt32 = 0o160000
        var paths: [String] = []
        for entry in indexSnapshot.entries where (entry.mode & 0o170000) == gitlinkMode {
            let gitlinkURL = URL(fileURLWithPath: repository.workTreeRoot)
                .appendingPathComponent(entry.path)
                .standardizedFileURL
            guard visitedWorkTreeRoots.insert(gitlinkURL.path).inserted,
                  let submoduleRepository = resolveGitRepository(containing: gitlinkURL.path),
                  submoduleRepository.workTreeRoot == gitlinkURL.path else {
                continue
            }
            paths.append(contentsOf: gitRepositoryMetadataWatchPaths(repository: submoduleRepository))
            paths.append(
                contentsOf: gitlinkMetadataWatchPaths(
                    repository: submoduleRepository,
                    visitedWorkTreeRoots: &visitedWorkTreeRoots
                )
            )
        }
        return paths
    }
}
