/// Reports a failure to resolve or read repository changes.
public enum ChangesEngineError: Error, Sendable, Equatable {
    /// The supplied baseline cannot be resolved to a Git tree.
    case invalidBase(String)
    /// No supported default branch exists for branch-base resolution.
    case defaultBranchNotFound
    /// A Git subprocess failed or returned malformed output.
    case gitFailed(String)
    /// A repository-relative path is empty, absolute, or escapes the repository.
    case invalidPath(String)
    /// The paging cursor is malformed or outside the available row range.
    case invalidCursor(String)
    /// The requested path has no diff and is not an untracked file.
    case fileNotChanged(String)
    /// File content could not be decoded as UTF-8 text.
    case unreadableText(String)
}
