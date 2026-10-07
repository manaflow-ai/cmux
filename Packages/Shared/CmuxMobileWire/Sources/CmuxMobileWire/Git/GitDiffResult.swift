/// `git.diff` result, the session host's `GitDiffResult`.
public struct GitDiffResult: Hashable, Sendable, Codable {
    public var scope: GitDiffScope
    /// The repository's top level; join it to a file's path.
    public var root: String
    public var head: String?
    /// The compared commit (merge base for `branch`, first parent for `committed`).
    public var base: String?
    public var files: [GitChangedFile]
    public var additions: Int
    public var deletions: Int
    /// Changed files before `max_files`.
    public var totalFiles: Int
    public var filesOmitted: Int
    public var untrackedSkipped: Int?

    public init(scope: GitDiffScope, root: String, head: String? = nil, base: String? = nil, files: [GitChangedFile],
                additions: Int, deletions: Int, totalFiles: Int, filesOmitted: Int = 0, untrackedSkipped: Int? = nil) {
        self.scope = scope
        self.root = root
        self.head = head
        self.base = base
        self.files = files
        self.additions = additions
        self.deletions = deletions
        self.totalFiles = totalFiles
        self.filesOmitted = filesOmitted
        self.untrackedSkipped = untrackedSkipped
    }

    enum CodingKeys: String, CodingKey {
        case scope, root, head, base, files, additions, deletions
        case totalFiles = "total_files"
        case filesOmitted = "files_omitted"
        case untrackedSkipped = "untracked_skipped"
    }
}
