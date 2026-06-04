/// Parameters for `mobile.terminal.mouse` requests (a forwarded tap/click).
public struct MobileTerminalMouseParams: Encodable, Sendable {
    /// The workspace owning the target terminal.
    public var workspaceID: String
    /// The target terminal surface.
    public var surfaceID: String
    /// The per-install client id the Mac keys viewport pins by.
    public var clientID: String
    /// The grid column of the click.
    public var col: Int
    /// The grid row of the click.
    public var row: Int

    /// Create terminal-mouse parameters.
    /// - Parameters:
    ///   - workspaceID: The workspace owning the target terminal.
    ///   - surfaceID: The target terminal surface.
    ///   - clientID: The per-install client id the Mac keys viewport pins by.
    ///   - col: The grid column of the click.
    ///   - row: The grid row of the click.
    public init(
        workspaceID: String,
        surfaceID: String,
        clientID: String,
        col: Int,
        row: Int
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.clientID = clientID
        self.col = col
        self.row = row
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case clientID = "client_id"
        case col
        case row
    }
}
