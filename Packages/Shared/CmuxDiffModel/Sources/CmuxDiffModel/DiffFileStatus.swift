/// File-level status values shown in the diff review file list.
public enum DiffFileStatus: String, Sendable, Codable, Equatable {
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
