/// Why a repository watcher left the normal direct-stat mode.
public enum GitWorkspaceMetadataWatchDegradation: Equatable, Sendable {
    /// Dirty checks use bounded `git status`; path-aware work-tree events remain enabled.
    case boundedGitStatus(entryCount: Int, directEntryLimit: Int)

    /// The tracked-path filter exceeded its budget, so all work-tree events are
    /// accepted behind a longer throttle and checked with bounded `git status`.
    case unfilteredWorkTreeEvents(
        entryCount: Int,
        trackedPathLimit: Int,
        indexByteCount: Int64,
        indexByteLimit: Int,
        throttleSeconds: Int
    )

    /// An existing index could not be parsed, so only Git metadata stays watched
    /// until a later index event can rebuild a safe work-tree event plan.
    case unreadableIndex

    /// A privacy-safe diagnostic describing the selected fallback and bound.
    public var logDescription: String {
        switch self {
        case .boundedGitStatus(let entryCount, let directEntryLimit):
            return "strategy=bounded-git-status reason=tracked-entry-limit "
                + "count=\(entryCount) limit=\(directEntryLimit)"
        case .unfilteredWorkTreeEvents(
            let entryCount,
            let trackedPathLimit,
            let indexByteCount,
            let indexByteLimit,
            let throttleSeconds
        ):
            return "strategy=rate-limited-worktree-events+bounded-git-status "
                + "reason=tracked-path-filter-budget entryCount=\(entryCount) "
                + "entryLimit=\(trackedPathLimit) indexBytes=\(indexByteCount) "
                + "indexByteLimit=\(indexByteLimit) throttleSeconds=\(throttleSeconds)"
        case .unreadableIndex:
            return "strategy=git-metadata-events-only reason=unreadable-index"
        }
    }
}
