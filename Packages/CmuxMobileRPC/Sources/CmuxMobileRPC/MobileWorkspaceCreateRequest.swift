/// The `workspace.create` request (no payload fields).
///
/// Encodes as the empty JSON object `{}` so the wire shape matches the legacy
/// parameterless envelopes.
public struct MobileWorkspaceCreateRequest: MobileRPCRequest {
    /// The bound JSON-RPC method name.
    public static let method = "workspace.create"

    /// Create workspace-create parameters.
    public init() {}
}
