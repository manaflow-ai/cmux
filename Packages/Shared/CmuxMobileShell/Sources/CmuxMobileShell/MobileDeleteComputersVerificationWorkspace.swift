#if DEBUG
/// One workspace row captured by the delete-computers simulator verifier.
public struct MobileDeleteComputersVerificationWorkspace: Codable, Equatable, Sendable {
    /// Stable workspace identifier shown in the workspace list.
    public var id: String
    /// Display name shown for the workspace.
    public var name: String
    /// Mac device id that owns the workspace row, when known.
    public var macDeviceID: String?
    /// Workspace-row connection status rendered by the verifier.
    public var status: String?
}
#endif
