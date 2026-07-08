/// File-level git status used by mobile diff review.
public enum GitDiffStatus: String, Sendable, Codable, Equatable {
    /// Added file.
    case added = "A"
    /// Modified file.
    case modified = "M"
    /// Deleted file.
    case deleted = "D"
    /// Renamed file.
    case renamed = "R"
    /// Untracked file.
    case untracked = "U"
}
