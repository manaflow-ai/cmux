/// Optional policy for creating a plain Git worktree.
public struct WorktreeCreateOptions: Sendable {
    /// A trusted branch prefix such as `cmux/`; the final ref is still checked by Git.
    public var branchPrefix: String?

    /// An optional branch-name seed separate from the display/path name.
    public var branchName: String?

    /// An exact absolute path, or a relative path resolved beneath `repoRoot`.
    public var worktreePath: String?

    /// Whether repositories with `.gitmodules` initialize submodules after add.
    public var initializeSubmodules: Bool

    /// Creates worktree options.
    /// - Parameters:
    ///   - branchPrefix: A trusted optional prefix for the sanitized branch seed.
    ///   - branchName: An optional branch seed; `name` is used when omitted.
    ///   - worktreePath: An exact path override; relative paths resolve beneath the repository.
    ///   - initializeSubmodules: Whether to initialize submodules when `.gitmodules` exists.
    public init(
        branchPrefix: String? = nil,
        branchName: String? = nil,
        worktreePath: String? = nil,
        initializeSubmodules: Bool = true
    ) {
        self.branchPrefix = branchPrefix
        self.branchName = branchName
        self.worktreePath = worktreePath
        self.initializeSubmodules = initializeSubmodules
    }
}
