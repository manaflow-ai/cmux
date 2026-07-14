/// Parameters for `mobile.workspace.changes.summary`.
public struct MobileChangesSummaryRequest: Codable, Sendable, Equatable {
    /// The Mac-local workspace identifier.
    public let workspaceID: String
    /// The baseline used for the comparison.
    public let baseSpec: MobileChangesBaseSpec
    /// Whether Git should ignore whitespace changes.
    public let ignoreWhitespace: Bool

    /// Creates a summary request.
    /// - Parameters:
    ///   - workspaceID: The Mac-local workspace identifier.
    ///   - baseSpec: The baseline used for the comparison.
    ///   - ignoreWhitespace: Whether Git should ignore whitespace changes.
    public init(workspaceID: String, baseSpec: MobileChangesBaseSpec, ignoreWhitespace: Bool) {
        self.workspaceID = workspaceID
        self.baseSpec = baseSpec
        self.ignoreWhitespace = ignoreWhitespace
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case baseSpec = "base_spec"
        case ignoreWhitespace = "ignore_whitespace"
    }
}
