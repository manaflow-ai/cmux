import CmuxLinkSignaling
import CmuxLink

/// What a connection needs from its carrier or acceptor.
struct WebRTCConnectionContext: Sendable {
    let session: String
    let hostID: String
    /// Signs our fingerprint bindings; nil for the unauthenticated V2
    /// underlay (WireGuard is its security boundary).
    let identity: (any WebRTCIdentity)?
    let signaling: any SignalingChannel
    let router: SignalRouter
    let iceCache: ICEConfigurationCache
    let configuration: WebRTCConfiguration
    let injector: WebRTCFaultInjector?
}
