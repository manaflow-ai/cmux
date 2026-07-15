/// A pre-stamped tracked snapshot request.
///
/// The optional authority is `nil` only for readers that cannot resolve a real
/// repository, such as isolated state-machine tests. Production watched
/// repositories stamp it before their snapshot waits on the probe limiter.
public nonisolated enum GitTrackedChangesSnapshotRequest: Equatable, Sendable {
    /// A filesystem watcher advanced the repository revision.
    case watcherEvent(
        GitTrackedChangesSnapshotAuthority?,
        eventID: GitTrackedPathEventGeneration? = nil
    )
    /// One explicit process-wide safety round.
    case fallbackRound(
        id: GitFallbackRoundID,
        authority: GitTrackedChangesSnapshotAuthority?
    )

    var authority: GitTrackedChangesSnapshotAuthority? {
        switch self {
        case .watcherEvent(let authority, _):
            authority
        case .fallbackRound(_, let authority):
            authority
        }
    }
}
