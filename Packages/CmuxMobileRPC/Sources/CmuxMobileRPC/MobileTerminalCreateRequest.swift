/// The `terminal.create` / `mobile.terminal.create` request.
public struct MobileTerminalCreateRequest: MobileRPCRequest {
    /// The bound JSON-RPC method name.
    public static let method = "terminal.create"

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
