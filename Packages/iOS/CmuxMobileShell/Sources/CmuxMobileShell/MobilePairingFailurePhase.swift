/// The lifecycle point where a pairing failure was detected.
enum MobilePairingFailurePhase: String, Equatable, Sendable {
    /// Input was rejected before route selection or connection.
    case validation
    /// The device failed a network reachability preflight.
    case preflight
    /// Route selection found no dialable secure route.
    case routeSelection = "route_selection"
    /// The connection or handshake attempt failed.
    case connect
    /// A request on an already-live connection failed.
    case operation
    /// Authorization failed after the connection path was established.
    case auth
}
