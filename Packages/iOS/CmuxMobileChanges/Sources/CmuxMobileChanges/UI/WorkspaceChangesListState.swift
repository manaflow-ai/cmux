/// Presentation state for the workspace file list.
public enum WorkspaceChangesListState: Sendable, Equatable {
    /// Placeholder rows are visible while loading.
    case loading
    /// The request failed and can be retried.
    case error
    /// The repository has no changes relative to its base.
    case empty
    /// The workspace directory is not inside a Git repository.
    case notARepository
    /// Changed-file snapshots are ready.
    /// - Parameter truncated: Whether the host omitted files beyond its list cap.
    case loaded(truncated: Bool)

    /// Whether the loaded list should explain that additional files were omitted.
    public var showsTruncatedFilesFooter: Bool {
        guard case .loaded(truncated: true) = self else { return false }
        return true
    }
}
