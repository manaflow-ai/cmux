/// Structured workspace-diffs failures that callers can handle without parsing messages.
public enum MobileDiffsServiceError: Error, Sendable, Equatable {
    /// The requested workspace does not exist on the connected Mac.
    case unknownWorkspace
    /// The requested workspace directory is not a Git repository.
    case notGitRepository
    /// The requested agent-turn baseline is unavailable.
    case baselineMissing
}
