/// Parameters for one page of `mobile.workspace.changes.file`.
public struct MobileChangesFileRequest: Codable, Sendable, Equatable {
    /// The Mac-local workspace identifier.
    public let workspaceID: String
    /// The new-side repository-relative path.
    public let path: String
    /// The old-side path for a rename or copy, when present.
    public let oldPath: String?
    /// The opaque paging cursor returned by the previous response.
    public let cursor: String?
    /// Whether Git should ignore whitespace changes.
    public let ignoreWhitespace: Bool
    /// The baseline used for the comparison.
    public let baseSpec: MobileChangesBaseSpec

    /// Creates a file-diff page request.
    /// - Parameters:
    ///   - workspaceID: The Mac-local workspace identifier.
    ///   - path: The new-side repository-relative path.
    ///   - oldPath: The old-side path for a rename or copy, when present.
    ///   - cursor: The opaque paging cursor, or `nil` for the first page.
    ///   - ignoreWhitespace: Whether Git should ignore whitespace changes.
    ///   - baseSpec: The baseline used for the comparison.
    public init(
        workspaceID: String,
        path: String,
        oldPath: String?,
        cursor: String?,
        ignoreWhitespace: Bool,
        baseSpec: MobileChangesBaseSpec
    ) {
        self.workspaceID = workspaceID
        self.path = path
        self.oldPath = oldPath
        self.cursor = cursor
        self.ignoreWhitespace = ignoreWhitespace
        self.baseSpec = baseSpec
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case path
        case oldPath = "old_path"
        case cursor
        case ignoreWhitespace = "ignore_whitespace"
        case baseSpec = "base_spec"
    }
}
