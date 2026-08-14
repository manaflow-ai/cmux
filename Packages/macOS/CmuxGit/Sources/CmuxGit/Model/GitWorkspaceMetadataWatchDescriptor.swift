import Foundation

/// Why a repository watcher left the normal direct-stat mode.
public enum GitWorkspaceMetadataWatchDegradation: Equatable, Sendable {
    /// Dirty checks use bounded `git status`; path-aware work-tree events remain enabled.
    case boundedGitStatus(entryCount: Int, directEntryLimit: Int)
    /// The tracked-path filter itself exceeded its bound, so work-tree events are disabled.
    case metadataOnly(entryCount: Int, trackedPathLimit: Int)

    public var logDescription: String {
        switch self {
        case .boundedGitStatus(let entryCount, let directEntryLimit):
            return "strategy=bounded-git-status reason=tracked-entry-limit "
                + "count=\(entryCount) limit=\(directEntryLimit)"
        case .metadataOnly(let entryCount, let trackedPathLimit):
            return "strategy=metadata-only-events+bounded-git-status "
                + "reason=tracked-path-filter-limit count=\(entryCount) limit=\(trackedPathLimit)"
        }
    }
}

/// Git-aware plan for deciding which recursive filesystem events can change
/// the sidebar branch or dirty state.
public struct GitWorkspaceMetadataWatchDescriptor: Equatable, Sendable {
    public let repositoryRoot: String
    public let watchedPaths: [String]
    public let gitMetadataPaths: [String]
    public let trackedEntryPaths: [String]
    public let degradation: GitWorkspaceMetadataWatchDegradation?

    public init(
        repositoryRoot: String,
        watchedPaths: [String],
        gitMetadataPaths: [String],
        trackedEntryPaths: [String],
        degradation: GitWorkspaceMetadataWatchDegradation? = nil
    ) {
        self.repositoryRoot = repositoryRoot
        self.watchedPaths = watchedPaths
        self.gitMetadataPaths = gitMetadataPaths
        self.trackedEntryPaths = trackedEntryPaths
        self.degradation = degradation
    }

    /// Empty path detail and FSEvents overflow are conservatively relevant.
    public func containsRelevantChange(
        paths: [String],
        requiresFullRescan: Bool = false
    ) -> Bool {
        guard !requiresFullRescan, !paths.isEmpty else { return true }
        return paths.contains { containsRelevantChange(path: $0) }
    }

    public func containsRelevantChange(path: String) -> Bool {
        containsRelevantChange(normalizedPath: Self.normalizedPath(path))
            || Self.alternateVarPath(for: path).map(containsRelevantChange(normalizedPath:)) == true
    }

    /// Whether a change may alter the watch plan itself (index/config/submodules).
    public func containsGitMetadataChange(
        paths: [String],
        requiresFullRescan: Bool = false
    ) -> Bool {
        guard !requiresFullRescan, !paths.isEmpty else { return true }
        return paths.contains { rawPath in
            let path = Self.normalizedPath(rawPath)
            if gitMetadataPaths.contains(where: { Self.pathsOverlap(path, $0) }) {
                return true
            }
            guard let alternate = Self.alternateVarPath(for: path) else { return false }
            return gitMetadataPaths.contains(where: { Self.pathsOverlap(alternate, $0) })
        }
    }

    private func containsRelevantChange(normalizedPath path: String) -> Bool {
        if gitMetadataPaths.contains(where: { Self.pathsOverlap(path, $0) }) {
            return true
        }
        guard !trackedEntryPaths.isEmpty else { return false }
        let exactIndex = lowerBound(for: path)
        if exactIndex < trackedEntryPaths.endIndex, trackedEntryPaths[exactIndex] == path {
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
            let middle = low + (high - low) / 2
            if trackedEntryPaths[middle] < value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        isSameOrInside(lhs, root: rhs) || isSameOrInside(rhs, root: lhs)
    }

    private static func isSameOrInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func normalizedPath(_ path: String) -> String {
        if !path.contains("//"), !path.contains("/./"), !path.contains("/../"),
           !path.hasSuffix("/."), !path.hasSuffix("/..") {
            return path
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func alternateVarPath(for path: String) -> String? {
        let normalized = normalizedPath(path)
        if normalized == "/var" { return "/private/var" }
        if normalized.hasPrefix("/var/") { return "/private" + normalized }
        if normalized == "/private/var" { return "/var" }
        if normalized.hasPrefix("/private/var/") {
            return String(normalized.dropFirst("/private".count))
        }
        return nil
    }
}
