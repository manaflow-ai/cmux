/// The `mobile.terminal.replay` request (cold-attach/self-heal).
public struct MobileTerminalReplayRequest: MobileRPCRequest {
    /// The bound JSON-RPC method name.
    public static let method = "mobile.terminal.replay"

    /// The workspace owning the target terminal.
    public var workspaceID: String
    /// The target terminal surface.
    public var surfaceID: String

    /// Create terminal-replay parameters.
    /// - Parameters:
    ///   - workspaceID: The workspace owning the target terminal.
    ///   - surfaceID: The target terminal surface.
    public init(workspaceID: String, surfaceID: String) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
    }
}
