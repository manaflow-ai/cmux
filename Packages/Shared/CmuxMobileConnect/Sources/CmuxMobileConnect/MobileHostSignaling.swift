public import CmuxLinkSignaling
public import CmuxLinkWebRTC

/// One Mac's signaling relay (B1's HostDO socket, `ControlPlaneSignaling` on
/// the phone) and its ICE servers (B1's TURN minting). B2 and B3 share the
/// router, so one socket carries both carriers' offers.
public struct MobileHostSignaling: Sendable {
    public var router: SignalRouter
    public var iceServers: any ICEServerProvider
    /// Closes the relay socket when the Mac leaves the registry.
    public var close: @Sendable () async -> Void

    public init(router: SignalRouter, iceServers: any ICEServerProvider, close: @escaping @Sendable () async -> Void = {}) {
        self.router = router
        self.iceServers = iceServers
        self.close = close
    }
}
