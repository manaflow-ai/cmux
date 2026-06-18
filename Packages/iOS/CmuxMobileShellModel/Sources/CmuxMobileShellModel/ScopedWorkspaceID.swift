/// A workspace identity that is unambiguous across multiple Macs.
///
/// Bare ``MobileWorkspacePreview/ID`` strings are Mac-local: two Macs can both
/// report `"workspace-1"`. In the unified multi-Mac list the selection and any
/// routed request must know *which* Mac a workspace belongs to, so the
/// composite's scoped selection is keyed on this pair rather than the bare id.
///
/// Invariant: ``workspaceID`` stays Mac-local (it is the wire id sent to that
/// Mac's RPC client) and ``deviceId`` only selects which client to send to —
/// the two are never crossed or concatenated into the wire id.
public struct ScopedWorkspaceID: Hashable, Sendable, Codable {
    /// The owning Mac's cmux device UUID (matches
    /// ``MobileWorkspacePreview/deviceId``). `""` is the unscoped/single-Mac
    /// case.
    public var deviceId: String
    /// The Mac-local workspace identifier (the wire id).
    public var workspaceID: MobileWorkspacePreview.ID

    /// Creates a scoped workspace identity.
    /// - Parameters:
    ///   - deviceId: The owning Mac's cmux device UUID. Defaults to `""`.
    ///   - workspaceID: The Mac-local workspace identifier.
    public init(deviceId: String = "", workspaceID: MobileWorkspacePreview.ID) {
        self.deviceId = deviceId
        self.workspaceID = workspaceID
    }

    /// The scoped identity for a workspace preview, taking its `deviceId` and
    /// `id` together.
    /// - Parameter workspace: The workspace whose scoped identity is wanted.
    public init(_ workspace: MobileWorkspacePreview) {
        self.init(deviceId: workspace.deviceId, workspaceID: workspace.id)
    }
}
