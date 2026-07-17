/// Domain failures surfaced by workspace diff operations.
public enum WorkspaceDiffError: Error, Sendable, Equatable {
    /// The repository or requested file no longer exists.
    case notFound
    /// Git could not read the repository state.
    case gitFailed
    /// Git or the request exceeded its deadline.
    case timedOut
    /// The selected row belongs to an older repository snapshot.
    case staleRepository
    /// Diff review is unavailable or returned malformed data.
    case unavailable
}
