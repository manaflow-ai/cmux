import Foundation

/// Git-aware plan for deciding which recursive filesystem events can change
/// the sidebar branch or dirty state.
public struct GitWorkspaceMetadataWatchDescriptor: Equatable, Sendable {
    /// Native Swift path to the repository working-tree root.
    public let repositoryRoot: String
    /// Existing filesystem roots passed to the recursive watcher.
    public let watchedPaths: [String]
    /// Paths whose changes can alter the Git watch plan itself.
    public let gitMetadataPaths: [String]
    /// Sorted native Swift paths for tracked entries used by exact filtering.
    public let trackedEntryPaths: [String]
    /// Whether every work-tree path is conservatively relevant. This is enabled
    /// only when retaining an exact tracked-path filter would cross its budget.
    public let acceptsAllWorkTreeEvents: Bool
    /// Leading-edge event throttle used by the recursive watcher.
    public let eventCoalescingInterval: Duration
    /// Stable identity for the immutable relevance filter. A changed identity
    /// creates a fresh shared watcher instead of mutating filter state in place.
    public let eventFilterIdentity: String?
    /// The active safety-valve mode, or `nil` for normal direct-stat operation.
    public let degradation: GitWorkspaceMetadataWatchDegradation?

    /// Creates an immutable Git-aware filesystem event plan.
    ///
    /// - Parameters:
    ///   - repositoryRoot: Native Swift path to the working-tree root.
    ///   - watchedPaths: Existing roots passed to the recursive watcher.
    ///   - gitMetadataPaths: Paths whose changes can rebuild this plan.
    ///   - trackedEntryPaths: Sorted tracked paths used by exact filtering.
    ///   - acceptsAllWorkTreeEvents: Whether every work-tree event is relevant.
    ///   - eventCoalescingInterval: Leading-edge watcher throttle.
    ///   - eventFilterIdentity: Stable identity for the immutable path filter.
    ///   - degradation: Active safety-valve mode, if any.
    public init(
        repositoryRoot: String,
        watchedPaths: [String],
        gitMetadataPaths: [String],
        trackedEntryPaths: [String],
        acceptsAllWorkTreeEvents: Bool,
        eventCoalescingInterval: Duration,
        eventFilterIdentity: String?,
        degradation: GitWorkspaceMetadataWatchDegradation? = nil
    ) {
        self.repositoryRoot = repositoryRoot
        self.watchedPaths = watchedPaths
        self.gitMetadataPaths = gitMetadataPaths
        self.trackedEntryPaths = trackedEntryPaths
        self.acceptsAllWorkTreeEvents = acceptsAllWorkTreeEvents
        self.eventCoalescingInterval = eventCoalescingInterval
        self.eventFilterIdentity = eventFilterIdentity
        self.degradation = degradation
    }

    /// Returns whether any path in a coalesced batch can change sidebar Git state.
    ///
    /// Empty path detail and FSEvents overflow are conservatively relevant.
    ///
    /// - Parameters:
    ///   - paths: Absolute paths from one bounded FSEvents batch.
    ///   - requiresFullRescan: Whether the event source lost path history.
    /// - Returns: `true` when callers must run an authoritative re-check.
    public func containsRelevantChange(
        paths: [String],
        requiresFullRescan: Bool = false
    ) -> Bool {
        guard !requiresFullRescan, !paths.isEmpty else { return true }
        return paths.contains { containsRelevantChange(path: $0) }
    }

    /// Returns whether one absolute path can change sidebar Git state.
    ///
    /// - Parameter path: Absolute filesystem path reported by FSEvents.
    /// - Returns: `true` when the path overlaps Git metadata or tracked content.
    public func containsRelevantChange(path: String) -> Bool {
        containsRelevantChange(normalizedPath: Self.normalizedPath(path))
            || Self.alternateVarPath(for: path).map(containsRelevantChange(normalizedPath:)) == true
    }

    /// Returns whether a batch may alter the watch plan itself.
    ///
    /// - Parameters:
    ///   - paths: Absolute paths from one bounded FSEvents batch.
    ///   - requiresFullRescan: Whether the event source lost path history.
    /// - Returns: `true` for index, config, ref, and submodule metadata changes.
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
        if acceptsAllWorkTreeEvents,
           Self.isSameOrInside(path, root: repositoryRoot) {
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
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return String(decoding: standardized.utf8, as: UTF8.self)
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
