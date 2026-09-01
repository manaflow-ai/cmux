/// Loading phase for the filesystem-backed Artifacts sidebar.
public enum ArtifactSidebarPhase: Equatable, Sendable {
    /// No local workspace is selected.
    case unavailable
    /// Project resolution or filesystem scanning is in progress.
    case loading
    /// A live filesystem snapshot is available.
    case loaded
    /// The project artifact store could not be loaded.
    case failed
}
