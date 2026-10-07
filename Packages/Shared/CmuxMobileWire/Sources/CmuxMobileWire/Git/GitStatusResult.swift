/// `git.status` result, the session host's `GitStatusResult`.
public struct GitStatusResult: Hashable, Sendable, Codable {
    /// The repository's top level.
    public var root: String
    /// Absent when HEAD is detached.
    public var branch: String?
    public var detached: Bool
    /// The HEAD commit, absent before the first commit.
    public var head: String?
    /// For example `origin/main`.
    public var upstream: String?
    /// The branch the `branch` scope compares with.
    public var base: String?
    public var ahead: Int
    public var behind: Int

    public init(root: String, branch: String? = nil, detached: Bool = false, head: String? = nil, upstream: String? = nil,
                base: String? = nil, ahead: Int = 0, behind: Int = 0) {
        self.root = root
        self.branch = branch
        self.detached = detached
        self.head = head
        self.upstream = upstream
        self.base = base
        self.ahead = ahead
        self.behind = behind
    }
}
