/// Which side of a signaling session a connection is.
enum WebRTCConnectionRole: Sendable {
    /// The phone: offers first, expects the pinned host key (nil when the
    /// session is unauthenticated, the V2 underlay), drives ICE restarts.
    case dialer(hostKey: WebRTCPublicKey?)
    /// The Mac: answers, asks the trust store about the device key (nil for
    /// the V2 underlay, where WireGuard authenticates).
    case host(authorizer: (any WebRTCAuthorizer)?)

    var isDialer: Bool {
        if case .dialer = self { return true }
        return false
    }
}
