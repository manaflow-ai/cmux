/// Parameters for `terminal.input` / `mobile.terminal.input` requests.
///
/// The viewport fields ride along with input so the Mac can pin this device's
/// viewport before applying the keystrokes; they are omitted from the wire when
/// no viewport has been reported yet.
public struct MobileTerminalInputParams: Encodable, Sendable {
    /// The workspace owning the target terminal.
    public var workspaceID: String
    /// The target terminal surface.
    public var surfaceID: String
    /// The UTF-8 text (or VT byte sequence) to inject.
    public var text: String
    /// The per-install client id the Mac keys viewport pins by.
    public var clientID: String
    /// The device's current viewport width in columns; omitted when `nil`.
    public var viewportColumns: Int?
    /// The device's current viewport height in rows; omitted when `nil`.
    public var viewportRows: Int?

    /// Create terminal-input parameters.
    /// - Parameters:
    ///   - workspaceID: The workspace owning the target terminal.
    ///   - surfaceID: The target terminal surface.
    ///   - text: The UTF-8 text (or VT byte sequence) to inject.
    ///   - clientID: The per-install client id the Mac keys viewport pins by.
    ///   - viewportColumns: The current viewport width in columns, if reported.
    ///   - viewportRows: The current viewport height in rows, if reported.
    public init(
        workspaceID: String,
        surfaceID: String,
        text: String,
        clientID: String,
        viewportColumns: Int? = nil,
        viewportRows: Int? = nil
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.text = text
        self.clientID = clientID
        self.viewportColumns = viewportColumns
        self.viewportRows = viewportRows
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case text
        case clientID = "client_id"
        case viewportColumns = "viewport_columns"
        case viewportRows = "viewport_rows"
    }
}
