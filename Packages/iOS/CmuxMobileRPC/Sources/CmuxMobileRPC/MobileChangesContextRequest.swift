/// Parameters for `mobile.workspace.changes.context`.
public struct MobileChangesContextRequest: Codable, Sendable, Equatable {
    /// The Mac-local workspace identifier.
    public let workspaceID: String
    /// The new-side repository-relative path.
    public let path: String
    /// The first one-based line to fetch, inclusive.
    public let startLine: Int
    /// The last one-based line to fetch, inclusive.
    public let endLine: Int
    /// The baseline used to resolve deleted-file content and workspace context.
    public let baseSpec: MobileChangesBaseSpec

    /// Creates a context-lines request.
    /// - Parameters:
    ///   - workspaceID: The Mac-local workspace identifier.
    ///   - path: The new-side repository-relative path.
    ///   - startLine: The first one-based line to fetch, inclusive.
    ///   - endLine: The last one-based line to fetch, inclusive.
    ///   - baseSpec: The baseline used to resolve the workspace changes context.
    public init(
        workspaceID: String,
        path: String,
        startLine: Int,
        endLine: Int,
        baseSpec: MobileChangesBaseSpec
    ) {
        self.workspaceID = workspaceID
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.baseSpec = baseSpec
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case path
        case startLine = "start_line"
        case endLine = "end_line"
        case baseSpec = "base_spec"
    }
}
