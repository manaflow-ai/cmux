/// Identifies the authenticated broker operation that produced a failure.
public enum IrxBrokerOperation: String, Codable, Equatable, Sendable {
    /// Endpoint binding registration or refresh.
    case register
    /// Account binding/trust discovery.
    case discover
    /// Relay credential minting.
    case mint
    /// Relay path-hint registration.
    case hintRefresh = "hint_refresh"
    /// Pair-grant minting.
    case pairGrant = "pair_grant"
    /// Binding revocation.
    case revoke
    /// Local endpoint binding or rebind work (not a broker HTTP operation).
    case endpoint
}
