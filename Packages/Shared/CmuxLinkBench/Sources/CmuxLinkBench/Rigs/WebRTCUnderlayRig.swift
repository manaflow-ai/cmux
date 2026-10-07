import CmuxLink
import CmuxLinkSignaling
import CmuxLinkWG
import CmuxLinkWGTesting
@_spi(Testing) import CmuxLinkWebRTC
import CmuxLinkWebRTCUnderlay

/// V2's real underlay: B2's datagram dialer and listener (one unreliable
/// `wg` data channel per peer connection) over the in-memory relay and
/// loopback ICE, with `WebRTCFaultInjector` behind `UnderlayFaults`.
struct WebRTCUnderlayRig: Sendable {
    /// The host id `WireGuardConformanceHarness` dials.
    static let hostID = "conformance-host"

    func endpoints() -> UnderlayEndpoints {
        let hub = InMemorySignalingHub()
        let injector = WebRTCFaultInjector()
        let listener = WebRTCDatagramListener(
            router: SignalRouter(channel: hub.endpoint(id: Self.hostID)),
            iceServers: StaticICEServerProvider(), hostID: Self.hostID,
            configuration: WebRTCBenchRig.configuration, injector: injector
        )
        let dialer = WebRTCDatagramDialer(
            router: SignalRouter(channel: hub.endpoint(id: WebRTCBenchRig.phoneInstall)),
            iceServers: StaticICEServerProvider(), configuration: WebRTCBenchRig.configuration, injector: injector
        )
        return UnderlayEndpoints(
            dialer: ListenerStartingDialer(inner: WebRTCUnderlayDialer(dialer: dialer), listener: ListenerStarter(listener: listener)),
            listener: WebRTCUnderlayListener(listener: listener),
            faults: InjectorUnderlayFaults(injector: injector),
            stop: { listener.stop() }
        )
    }
}
