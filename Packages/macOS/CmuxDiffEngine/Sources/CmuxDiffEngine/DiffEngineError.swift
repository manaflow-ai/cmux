/// Errors produced while resolving or reading a repository diff.
public enum DiffEngineError: Error, Sendable, Equatable {
    /// The requested directory is not inside a Git worktree.
    case notGitRepository
    /// A last-turn request did not include a resolved baseline object.
    case baselineUnavailable
    /// No usable default branch could be resolved.
    case defaultBranchUnavailable
    /// A repository-relative path was empty or escaped the repository root.
    case invalidPath(String)
    /// A requested changed file was not present in the selected diff.
    case fileNotFound(String)
    /// A context range or file-page cursor was invalid.
    case invalidRange
    /// A Git command failed, with its arguments and captured diagnostic.
    case commandFailed(arguments: [String], diagnostic: String)
}
