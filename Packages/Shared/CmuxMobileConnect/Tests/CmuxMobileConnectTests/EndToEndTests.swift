import CmuxLink
@_spi(Testing) import CmuxLinkDirect
import CmuxLinkSignaling
@_spi(Testing) import CmuxLinkWebRTC
import CmuxLinkTesting
import CmuxMobileConnect
@_spi(Testing) import CmuxMobileConnectHost
import CmuxMobileHost
import CmuxTerminalLink
import CmuxTerminalRenderCore
import CmuxTerminalStream
import Foundation
import Testing

/// The phone's `MobileLinkRegistry` -> `PathSelector` -> a real carrier ->
/// the Mac's `MobileHostAssembly` (`MobileHost` + scripted daemon) -> a
/// terminal: attach, input, resize, reconnect (d1-terminal-ux.md section 6).
@Suite("phone to Mac end to end", .serialized)
@MainActor
struct EndToEndTests {
    static let link = LinkConfiguration(handshakeTimeout: .seconds(5),
                                        backoff: Backoff(initial: .milliseconds(5), maximum: .milliseconds(50)),
                                        maxConnectAttempts: 100, resumeWindow: .seconds(30))
    static let policy = PathPolicy(preferenceWindow: .milliseconds(20), upgradeRetry: nil)
    static let webrtc = WebRTCConfiguration(connectTimeout: .seconds(10), iceRestartTimeout: .seconds(5),
                                            disconnectedGrace: .milliseconds(500), closeTimeout: .seconds(2),
                                            network: .loopbackOnly)
    static let loopback = DirectPathSnapshot(isSatisfied: true, interfaces: [DirectInterface(name: "lo0", kind: .loopback)])

    @Test("B4 direct over localhost: attach, input, resize, reconnect")
    func direct() async throws {
        let fixture = try await ConnectFixture()
        let daemon = ScriptedDaemon()
        let faults = DirectFaultInjector()
        let assembly = MobileHostAssembly(
            credentials: try fixture.hostCredentials(), trust: fixture.trust, daemon: daemon, signaling: nil,
            options: MobileHostAssemblyOptions(listen: DirectListenConfiguration(port: 0, localAddress: "127.0.0.1"), link: Self.link),
            features: MobileHostFeatures(), directFaults: faults, webrtcFaults: nil)
        let port = try await assembly.start()
        let registry = MobileLinkRegistry(credentials: try fixture.phoneCredentials(),
                                          options: MobileConnectOptions(link: Self.link, policy: Self.policy),
                                          snapshot: Self.loopback, signaling: { _ in nil })
        registry.update(routes: [try await fixture.route(targets: [.address(DirectAddress("127.0.0.1")!, port: port)])])
        #expect(registry.plan(for: ConnectFixture.hostID)?.admits(.webrtc) == false)

        try await Self.exercise(registry: registry, daemon: daemon, expected: LinkPath(kind: .direct, carrier: .direct)) {
            let live = faults.liveCount
            faults.dropAll()
            return live
        }
        registry.close()
        await assembly.stop()
    }

    @Test("B2 WebRTC over loopback ICE: attach, input, resize, reconnect")
    func webrtc() async throws {
        let fixture = try await ConnectFixture()
        let daemon = ScriptedDaemon()
        let faults = WebRTCFaultInjector()
        let hub = InMemorySignalingHub()
        let hostSignaling = MobileHostSignaling(router: SignalRouter(channel: hub.endpoint(id: ConnectFixture.hostID)),
                                                iceServers: StaticICEServerProvider(.hostOnly))
        let assembly = MobileHostAssembly(
            credentials: try fixture.hostCredentials(), trust: fixture.trust, daemon: daemon, signaling: hostSignaling,
            options: MobileHostAssemblyOptions(listen: DirectListenConfiguration(port: 0, localAddress: "127.0.0.1"),
                                               webrtc: Self.webrtc, link: Self.link),
            features: MobileHostFeatures(), directFaults: nil, webrtcFaults: faults)
        _ = try await assembly.start()
        let phoneChannel = hub.endpoint(id: ConnectFixture.phoneInstall)
        let registry = MobileLinkRegistry(
            credentials: try fixture.phoneCredentials(),
            options: MobileConnectOptions(webrtc: Self.webrtc, link: Self.link, policy: Self.policy),
            snapshot: Self.loopback,
            signaling: { _ in MobileHostSignaling(router: SignalRouter(channel: phoneChannel), iceServers: StaticICEServerProvider(.hostOnly)) })
        // No direct endpoint known: only WebRTC races.
        registry.update(routes: [try await fixture.route(targets: [])])
        #expect(registry.plan(for: ConnectFixture.hostID)?.admits(.direct) == false)

        try await Self.exercise(registry: registry, daemon: daemon, expected: LinkPath(kind: .p2p, carrier: .webrtc)) {
            let live = faults.liveCount
            await faults.dropAll()
            return live
        }
        registry.close()
        await assembly.stop()
    }

    /// One terminal through the registry's client: READY then bytes, ordered
    /// input, a resize that changes the grid, the live path badge, and input
    /// that still lands after `drop` cut the transport.
    static func exercise(registry: MobileLinkRegistry, daemon: ScriptedDaemon, expected: LinkPath,
                         drop: @escaping @Sendable () async -> Int) async throws {
        let client = try #require(registry.client(for: ConnectFixture.hostID))
        let source = LinkTerminalByteSource(terminal: "term_x1", client: client)
        let log = SourceLog(try await source.open(TerminalViewport(cols: 60, rows: 30, visible: true)))
        let attachment = try await within { try #require(await daemon.attachments.next()) }
        #expect(attachment.request.viewer.install == ConnectFixture.phoneInstall)
        let grid = try await log.grid()
        #expect(grid.cols == 60 && grid.rows == 30 && grid.generation == 7)
        attachment.ready(offset: 1000)
        #expect(try await log.frame(.snapshotReady).offset == 1000)
        attachment.bytes("hi", endingAt: 1002)
        #expect(try await log.frame(.bytes).payload == Data("hi".utf8))

        for key in ["l", "s", "\r"] { try await source.send(Data(key.utf8)) }
        try await attachment.waitFor("input:\r")
        #expect(await attachment.typed == "ls\r")

        await source.viewportChanged(TerminalViewport(cols: 40, rows: 20, visible: true))
        try await attachment.waitFor("viewport:40x20")
        let resized = try await log.grid()
        #expect(resized.cols == 40 && resized.rows == 20 && resized.generation == 8)
        #expect(try await log.frame(.snapshotReady).generation == 8)

        let badges = registry.pathBadges()
        let badge = try await within {
            for await map in badges { if let badge = map[ConnectFixture.hostID] { return badge } }
            throw TimeoutError()
        }
        #expect(badge.path == expected)

        #expect(await drop() >= 1, "a live transport was cut")
        try await source.send(Data("pwd\r".utf8))
        try await within(.seconds(20)) {
            while await attachment.typed != "ls\rpwd\r" {
                guard let entry = await attachment.recorded.next(), entry != "detach" else { throw TimeoutError() }
            }
        }
        await source.close()
    }
}
