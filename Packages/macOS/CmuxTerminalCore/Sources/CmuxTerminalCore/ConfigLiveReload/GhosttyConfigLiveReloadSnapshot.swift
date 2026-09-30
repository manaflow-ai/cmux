/// One point-in-time read of every file that feeds cmux's Ghostty configuration.
///
/// ``GhosttyConfigLiveReloadCoordinator`` compares snapshots to decide whether
/// a filesystem event changed what Ghostty would load. A directory event, an
/// editor's backup file, or cmux rewriting a file with identical bytes leaves
/// ``contentsByPath`` unchanged, so no reload is issued.
///
/// ```swift
/// let snapshot = GhosttyConfigDiscovery().liveReloadSnapshot(
///     topLevelPaths: ["/Users/me/.config/ghostty/config"],
///     configHomeDirectory: "/Users/me/.config"
/// )
/// ```
public struct GhosttyConfigLiveReloadSnapshot: Equatable, Sendable {
    /// Every path to watch, in discovery order and without duplicates.
    ///
    /// Includes top-level config candidates that do not exist yet, so creating
    /// one is noticed, plus `config-file` includes and user theme files.
    public let watchedPaths: [String]

    /// UTF-8 contents of each watched path that could be read.
    ///
    /// A path that is missing or unreadable has no entry, so creating or
    /// deleting a file changes this value.
    public let contentsByPath: [String: String]

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - watchedPaths: The ordered, de-duplicated paths to watch.
    ///   - contentsByPath: The contents of every readable watched path.
    public init(watchedPaths: [String], contentsByPath: [String: String]) {
        self.watchedPaths = watchedPaths
        self.contentsByPath = contentsByPath
    }

    /// Whether `other` has the same file contents, ignoring the watched path
    /// list (a missing include does not change what Ghostty loads).
    ///
    /// - Parameter other: The snapshot to compare against.
    /// - Returns: `true` when every readable file has identical contents.
    public func hasSameContents(as other: GhosttyConfigLiveReloadSnapshot) -> Bool {
        contentsByPath == other.contentsByPath
    }
}
