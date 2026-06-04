/// Parameters for `workspace.list` / `mobile.workspace.list` requests.
///
/// Both fields are optional: an unscoped list omits them from the wire entirely
/// (absent keys, not JSON nulls), matching the legacy `[String: Any]` shape.
public struct MobileWorkspaceListParams: Encodable, Sendable {
    /// Restrict the list to one workspace; omitted from the wire when `nil`.
    public var workspaceID: String?
    /// Restrict the list to one terminal in that workspace; omitted when `nil`.
    public var terminalID: String?

    /// Create workspace-list parameters.
    /// - Parameters:
    ///   - workspaceID: Optional workspace scope.
    ///   - terminalID: Optional terminal scope inside the workspace.
    public init(workspaceID: String? = nil, terminalID: String? = nil) {
        self.workspaceID = workspaceID
        self.terminalID = terminalID
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case terminalID = "terminal_id"
    }
}
