import CmuxLink
import CmuxLinkSignaling
import CmuxLinkTesting
import CmuxLinkWG
import CmuxLinkWGTesting
@_spi(Testing) import CmuxLinkWebRTC
import CmuxLinkWebRTCUnderlay
import Foundation
import Testing

extension LiveWebRTCTests {
/// B3's V2 carrier (WireGuard inside WebRTC) on B2's real loopback WebRTC
/// `wg` data channel: the A3 conformance suite through
/// `WireGuardConformanceHarness`, plus the underlay promises themselves.
@Suite("WireGuard over real WebRTC")
struct WireGuardOverWebRTCTests {
    @Test("conformance", arguments: ConformanceCase.allCases)
    func conformance(_ testCase: ConformanceCase) async throws {
        let harness = WireGuardConformanceHarness(name: "webrtc-wg-loopback") {
            WebRTCUnderlayRig().endpoints()
        }
        let outcome = try await LinkConformanceSuite(harness: harness).run(testCase)
        #expect(outcome == .passed)
    }

    @Test("datagrams cross the wg channel; close is a reset for the peer")
    func underlay() async throws {
        let rig = WebRTCUnderlayRig()
        let endpoints = rig.endpoints()
        let incoming = endpoints.listener.incoming
        async let accepted: (any DatagramUnderlay)? = { for await underlay in incoming { return underlay }; return nil }()
        let dialed = try await within { try await endpoints.dialer.open(to: LinkPeer(hostID: WebRTCUnderlayRig.hostID)) }
        let host = try #require(await accepted)
        #expect(await dialed.path == .p2p)
        #expect(dialed.maxDatagramBytes == 1200)
        try await dialed.send(Data("hello wg".utf8))
        let first = try await within { () -> Data? in
            for await event in host.events { if case let .datagram(data) = event { return data } }
            return nil
        }
        #expect(first == Data("hello wg".utf8))
        await dialed.close()
        let closed = try await within { () -> UnderlayCloseReason? in
            for await event in host.events { if case let .closed(reason) = event { return reason } }
            return nil
        }
        #expect(closed == .reset)
        await endpoints.stop()
    }

    @Test("a V1 offer and a V2 offer on one host socket reach their own acceptors")
    func sharedRouter() async throws {
        let hub = InMemorySignalingHub()
        let hostRouter = SignalRouter(channel: hub.endpoint(id: WebRTCPair.hostID))
        let phoneRouter = SignalRouter(channel: hub.endpoint(id: WebRTCPair.phoneInstall))
        let hostIdentity = SoftwareWebRTCIdentity()
        let deviceIdentity = SoftwareWebRTCIdentity()
        let configuration = WebRTCPair.configuration
        let acceptor = WebRTCAcceptor(
            router: hostRouter, iceServers: StaticICEServerProvider(), identity: hostIdentity, hostID: WebRTCPair.hostID,
            authorizer: WebRTCPinnedAuthorizer(devices: [deviceIdentity.publicKey]), configuration: configuration
        )
        await acceptor.start()
        let listener = WebRTCDatagramListener(router: hostRouter, iceServers: StaticICEServerProvider(), hostID: WebRTCPair.hostID, configuration: configuration)
        await listener.start()
        let carrier = WebRTCCarrier(router: phoneRouter, iceServers: StaticICEServerProvider(), identity: deviceIdentity, configuration: configuration)
        let dialer = WebRTCDatagramDialer(router: phoneRouter, iceServers: StaticICEServerProvider(), configuration: configuration)
        let peer = LinkPeer(hostID: WebRTCPair.hostID, hints: WebRTCHintsResolver().hints(hostKey: hostIdentity.publicKey))

        let transport = try await within { try await carrier.connect(to: peer) }
        let channel = try await within { try await dialer.open(to: peer) }
        #expect(await transport.path.carrier == .webrtc)
        #expect(await channel.path == .p2p)
        await transport.close()
        await channel.close()
        await acceptor.stop()
        listener.stop()
    }
}
}

/// B2's datagram dialer and listener over an in-memory relay and loopback
/// ICE, with `WebRTCFaultInjector` behind B3's `UnderlayFaults`.
struct WebRTCUnderlayRig: Sendable {
    /// The host id `WireGuardConformanceHarness` dials.
    static let hostID = "conformance-host"
    let hub = InMemorySignalingHub()
    let injector = WebRTCFaultInjector()

    func endpoints() -> UnderlayEndpoints {
        let configuration = WebRTCPair.configuration
        let listener = WebRTCDatagramListener(
            router: SignalRouter(channel: hub.endpoint(id: Self.hostID)),
            iceServers: StaticICEServerProvider(), hostID: Self.hostID,
            configuration: configuration, injector: injector
        )
        let dialer = WebRTCDatagramDialer(
            router: SignalRouter(channel: hub.endpoint(id: WebRTCPair.phoneInstall)),
            iceServers: StaticICEServerProvider(), configuration: configuration, injector: injector
        )
        let started = StartOnce(listener: listener)
        return UnderlayEndpoints(
            dialer: StartingDialer(inner: WebRTCUnderlayDialer(dialer: dialer), started: started),
            listener: WebRTCUnderlayListener(listener: listener),
            faults: InjectorFaults(injector: injector),
            stop: { listener.stop() }
        )
    }
}

/// Starts the listener before the first open (endpoints are built sync).
actor StartOnce {
    let listener: WebRTCDatagramListener
    private var started = false

    init(listener: WebRTCDatagramListener) {
        self.listener = listener
    }

    func ensure() async {
        guard !started else { return }
        started = true
        await listener.start()
    }
}

struct StartingDialer: DatagramUnderlayDialer {
    let inner: WebRTCUnderlayDialer
    let started: StartOnce

    func open(to peer: LinkPeer) async throws -> any DatagramUnderlay {
        await started.ensure()
        return try await inner.open(to: peer)
    }
}

struct InjectorFaults: UnderlayFaults {
    let injector: WebRTCFaultInjector

    func reset() async { await injector.resetAll() }
    func changePath(to kind: PathKind) async { await injector.changePath(to: kind) }
    func roam(to kind: PathKind) async { await injector.roam(to: kind) }
    func throttle(bytesPerSecond: Int?) async -> Bool {
        injector.throttle(bytesPerSecond: bytesPerSecond)
        return true
    }
}
