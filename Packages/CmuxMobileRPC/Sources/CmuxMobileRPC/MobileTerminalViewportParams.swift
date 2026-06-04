/// Parameters for `mobile.terminal.viewport` requests.
///
/// Two wire shapes share this method: a viewport report sends
/// `viewport_columns`/`viewport_rows`, and a detach sends `clear: true`. Absent
/// fields are omitted from the wire (not JSON nulls), matching the legacy
/// `[String: Any]` envelopes.
public struct MobileTerminalViewportParams: Encodable, Sendable {
    /// The workspace owning the target terminal.
    public var workspaceID: String
    /// The target terminal surface.
    public var surfaceID: String
    /// The per-install client id the Mac keys viewport pins by.
    public var clientID: String
    /// The device's viewport width in columns; omitted when `nil`.
    public var viewportColumns: Int?
    /// The device's viewport height in rows; omitted when `nil`.
    public var viewportRows: Int?
    /// `true` drops this device's viewport pin; omitted when `nil`.
    public var clear: Bool?

    /// Create terminal-viewport parameters.
    /// - Parameters:
    ///   - workspaceID: The workspace owning the target terminal.
    ///   - surfaceID: The target terminal surface.
    ///   - clientID: The per-install client id the Mac keys viewport pins by.
    ///   - viewportColumns: The viewport width in columns to report.
    ///   - viewportRows: The viewport height in rows to report.
    ///   - clear: Pass `true` to drop this device's viewport pin.
    public init(
        workspaceID: String,
        surfaceID: String,
        clientID: String,
        viewportColumns: Int? = nil,
        viewportRows: Int? = nil,
        clear: Bool? = nil
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.clientID = clientID
        self.viewportColumns = viewportColumns
        self.viewportRows = viewportRows
        self.clear = clear
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case clientID = "client_id"
        case viewportColumns = "viewport_columns"
        case viewportRows = "viewport_rows"
        case clear
    }
}
