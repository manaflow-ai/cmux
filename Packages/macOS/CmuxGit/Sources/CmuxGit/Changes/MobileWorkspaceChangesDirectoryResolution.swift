/// Provenance-aware result for a workspace-changes repository directory.
public enum MobileWorkspaceChangesDirectoryResolution: Sendable, Equatable {
    /// The workspace or its effective directory is unavailable.
    case unavailable
    /// The directory came from a remote workspace and must never reach local Git.
    case remote
    /// A local effective directory that may be inspected by local Git.
    case local(String)
}
