public import Foundation

/// The managed cmux context identity exported to a spawned terminal process.
///
/// These values become the `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID` /
/// `CMUX_SOCKET_PATH` (and legacy tab/panel alias) environment variables.
public struct TerminalSurfaceCmuxContextEnvironment: Equatable, Sendable {
    /// The owning workspace id (exported as `CMUX_WORKSPACE_ID` / `CMUX_TAB_ID`).
    public let workspaceId: UUID

    /// The surface id (exported as `CMUX_SURFACE_ID` / `CMUX_PANEL_ID`).
    public let surfaceId: UUID

    /// The control socket path (exported as `CMUX_SOCKET_PATH`).
    public let socketPath: String

    /// The workspace Notes tree root, when one should be exported.
    public var workspaceNotesDir: String?

    /// Creates the managed context identity.
    ///
    /// - Parameters:
    ///   - workspaceId: The owning workspace id.
    ///   - surfaceId: The surface id.
    ///   - socketPath: The control socket path.
    ///   - workspaceNotesDir: The workspace Notes tree root, if available.
    public init(
        workspaceId: UUID,
        surfaceId: UUID,
        socketPath: String,
        workspaceNotesDir: String? = nil
    ) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.socketPath = socketPath
        self.workspaceNotesDir = workspaceNotesDir
    }
}
