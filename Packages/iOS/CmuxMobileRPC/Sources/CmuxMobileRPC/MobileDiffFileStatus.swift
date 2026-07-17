/// The wire status of a changed file.
public enum MobileDiffFileStatus: String, Codable, Sendable, Equatable {
    /// A tracked file was added.
    case added
    /// A tracked file was modified.
    case modified
    /// A tracked file was deleted.
    case deleted
    /// A tracked file was renamed.
    case renamed
    /// A tracked file was copied.
    case copied
    /// A file is not tracked by Git.
    case untracked
}
