/// Parameters for `terminal.create` / `mobile.terminal.create` requests.
public struct MobileTerminalCreateParams: Encodable, Sendable {
    /// The workspace the new terminal is created in.
    public var workspaceID: String

    /// Create terminal-create parameters.
    /// - Parameter workspaceID: The workspace the new terminal is created in.
    public init(workspaceID: String) {
        self.workspaceID = workspaceID
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }
}
