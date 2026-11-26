/// A file's change category in a workspace snapshot.
public enum FileChangeKind: String, Sendable, Equatable, CaseIterable {
    /// A tracked file was added.
    case added
    /// A tracked file was modified.
    case modified
    /// A tracked file was deleted.
    case deleted
    /// A tracked file moved from another path.
    case renamed
    /// A file is not tracked by Git.
    case untracked
    /// The host reported a category this client does not recognize.
    case unknown
}
