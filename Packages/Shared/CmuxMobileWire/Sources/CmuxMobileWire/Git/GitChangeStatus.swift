/// How a file changed (the session host's `GitChangeStatus`).
public enum GitChangeStatus: String, Hashable, Sendable, Codable {
    case added
    case modified
    case deleted
    case renamed
    case untracked
}
