/// Parameters for `mobile.terminal.replay` requests (cold-attach/self-heal).
public struct MobileTerminalReplayParams: Encodable, Sendable {
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
