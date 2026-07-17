/// A typed failure suitable for a native diff-screen banner.
public enum DiffScreenErrorKind: Sendable, Equatable {
    /// The paired Mac no longer recognizes the workspace identifier.
    case unknownWorkspace
    /// The workspace directory is not a Git repository.
    case notGitRepository
    /// The selected agent-turn baseline is unavailable.
    case baselineMissing
    /// The request failed in transport or returned an unexpected response.
    case transport
}
