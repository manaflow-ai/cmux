/// Parameters for `workspace.create` requests (no payload fields).
///
/// Encodes as the empty JSON object `{}` so the wire shape matches the legacy
/// parameterless envelopes.
public struct MobileWorkspaceCreateParams: MobileRPCRequestParams {
    /// The bound JSON-RPC method name.
    public static let method = "workspace.create"

    /// Create workspace-create parameters.
    public init() {}
}
