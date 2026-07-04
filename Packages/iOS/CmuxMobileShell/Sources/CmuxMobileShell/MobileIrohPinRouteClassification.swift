/// Trust classification for one candidate route in a token-bearing iroh dial.
enum MobileIrohPinRouteClassification: Equatable, Sendable {
    /// The route is not an iroh peer, or its peer id matches the stored pin.
    case dialable
    /// No EndpointId is pinned yet; the caller may dial and then persist this id.
    case firstTrust(String)
    /// The route's iroh peer id differs from the stored pin and must not be dialed.
    case mismatch(pinned: String, advertised: String)

    var allowsTokenBearingDial: Bool {
        switch self {
        case .dialable, .firstTrust:
            return true
        case .mismatch:
            return false
        }
    }
}
