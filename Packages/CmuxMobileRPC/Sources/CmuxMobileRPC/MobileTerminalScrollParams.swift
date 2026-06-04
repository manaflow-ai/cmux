/// Parameters for `mobile.terminal.scroll` requests.
public struct MobileTerminalScrollParams: Encodable, Sendable {
    /// The workspace owning the target terminal.
    public var workspaceID: String
    /// The target terminal surface.
    public var surfaceID: String
    /// The per-install client id the Mac keys viewport pins by.
    public var clientID: String
    /// Signed scroll distance in lines (negative scrolls up). Fractional
    /// values are preserved on the wire (per-frame drag deltas).
    public var deltaLines: Double
    /// The grid column under the gesture.
    public var col: Int
    /// The grid row under the gesture.
    public var row: Int

    /// Create terminal-scroll parameters.
    /// - Parameters:
    ///   - workspaceID: The workspace owning the target terminal.
    ///   - surfaceID: The target terminal surface.
    ///   - clientID: The per-install client id the Mac keys viewport pins by.
    ///   - deltaLines: Signed scroll distance in lines (negative scrolls up).
    ///   - col: The grid column under the gesture.
    ///   - row: The grid row under the gesture.
    public init(
        workspaceID: String,
        surfaceID: String,
        clientID: String,
        deltaLines: Double,
        col: Int,
        row: Int
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.clientID = clientID
        self.deltaLines = deltaLines
        self.col = col
        self.row = row
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case clientID = "client_id"
        case deltaLines = "delta_lines"
        case col
        case row
    }
}
