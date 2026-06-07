/// The `mobile.host.status` request (no payload fields).
///
/// Encodes as the empty JSON object `{}` so the wire shape matches the legacy
/// parameterless envelopes. This is the one unauthenticated probe method.
public struct MobileHostStatusRequest: MobileRPCRequest {
    /// The bound JSON-RPC method name.
    public static let method = "mobile.host.status"

    /// Create host-status parameters.
    public init() {}
}
