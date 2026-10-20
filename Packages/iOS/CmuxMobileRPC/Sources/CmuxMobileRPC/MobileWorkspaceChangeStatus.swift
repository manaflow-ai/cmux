/// A wire-compatible workspace file-change category.
public enum MobileWorkspaceChangeStatus: String, Sendable, Equatable {
    /// A tracked path was added.
    case added
    /// A tracked path was modified.
    case modified
    /// A tracked path was deleted.
    case deleted
    /// A tracked path was renamed.
    case renamed
    /// A path is not tracked by Git.
    case untracked
    /// The host reported a status this client does not recognize.
    case unknown
}
