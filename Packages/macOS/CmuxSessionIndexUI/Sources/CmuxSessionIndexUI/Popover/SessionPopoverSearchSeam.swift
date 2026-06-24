public import CmuxSessionIndex

/// Closure type for paginated session search, handed down into the "Show more"
/// popover instead of a session-index store reference so views inside the lazy
/// list subtree cannot observe the store by accident.
///
/// Implemented app-side over `SessionIndexStore.searchSessions(query:scope:offset:limit:)`.
public typealias SessionSearchFn = @MainActor (
    _ query: String,
    _ scope: SearchScope,
    _ offset: Int,
    _ limit: Int
) async -> SearchOutcome

/// Closure type for fetching the full merged snapshot of a directory.
///
/// The popover uses this on the empty-query scroll path so pagination becomes an
/// in-memory slice instead of repeated store round-trips. Implemented app-side over
/// `SessionIndexStore.loadDirectorySnapshot(cwd:)`.
public typealias DirectorySnapshotFn = @MainActor (_ cwd: String?) async -> DirectorySnapshot
