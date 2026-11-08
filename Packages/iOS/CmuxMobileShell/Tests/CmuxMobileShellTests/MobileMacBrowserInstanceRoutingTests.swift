import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileTunnel
import Foundation
import Testing
@testable import CmuxMobileShell

/// A browser opened for Stable must not start using Nightly's connection
/// when both builds advertise the same physical Mac id (#16119).
@MainActor
@Suite struct MobileMacBrowserInstanceRoutingTests {
    @Test func switchingInstancesDoesNotReuseTheOtherBrowsersNetwork() throws {
        let fixture = try Fixture()
        defer { fixture.cleanDefaults() }
        try fixture.select(instanceTag: "stable")
        let stable = fixture.shell.macBrowserNetwork(for: "mac-a")
        #expect(stable === fixture.shell.macBrowserNetwork(for: "mac-a"))

        try fixture.select(instanceTag: "nightly")
        let nightly = fixture.shell.macBrowserNetwork(for: "mac-a")
        #expect(stable !== nightly)
        #expect(stable.registryOwner != nightly.registryOwner)
    }

    @Test func cachedBrowserRefusesLanesAfterSwitchingToSiblingInstance() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanDefaults() }
        try fixture.select(instanceTag: "stable")
        let stable = fixture.shell.macBrowserNetwork(for: "mac-a")
        let initial = try await stable.backend.open(host: "app.localhost", port: 5173)
        await initial.close()
        #expect(await fixture.probe.openedRoutes == ["stable"])

        try fixture.select(instanceTag: "nightly")
        do {
            let crossed = try await stable.backend.open(host: "app.localhost", port: 5173)
            await crossed.close()
            Issue.record("A browser owned by Stable opened a lane through Nightly")
        } catch {
            #expect(error as? TunnelOpenError == .unavailable)
        }
        #expect(await fixture.probe.openedRoutes == ["stable"])
    }

    @MainActor private struct Fixture {
        let shell: MobileShellComposite
        let probe = BrowserTunnelProbe()
        let suiteName = "cmux-browser-instance-\(UUID().uuidString)"
        let defaults: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suiteName))
            shell = MobileShellComposite(
                runtime: BrowserTunnelRuntime(probe: probe),
                connectionState: .connected,
                clientIDRepository: MobileClientIDRepository(defaults: defaults),
                reachability: AlwaysOnlineReachability(),
                pairingHintDefaults: defaults,
                multiMacAggregationDefaults: defaults
            )
            shell.supportedHostCapabilities = [MobileShellComposite.macBrowserTunnelCapability]
        }

        func select(instanceTag: String?) throws {
            let route = try CmxAttachRoute(
                id: instanceTag ?? "legacy",
                kind: .iroh,
                endpoint: .peer(
                    identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                    pathHints: []
                ),
                priority: 0
            )
            shell.foregroundMacDeviceID = "mac-a"
            shell.activeMacInstanceTag = instanceTag
            shell.activeRoute = route
            shell.activeTicket = try CmxAttachTicket(
                workspaceID: "workspace-a",
                terminalID: "terminal-a",
                macDeviceID: "mac-a",
                macDisplayName: "Test Mac",
                routes: [route],
                expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
            )
        }

        func cleanDefaults() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

private actor BrowserTunnelProbe {
    private(set) var openedRoutes: [String] = []

    func open(_ request: CmxByteTransportRequest) -> any MobileTunnelLaneConnection {
        openedRoutes.append(request.route.id)
        return EchoLane()
    }
}

private struct BrowserTunnelRuntime: MobileSyncRuntime {
    let probe: BrowserTunnelProbe
    let transportFactory: any CmxByteTransportFactory = LivenessTransportFactory(
        router: LivenessHostRouter(), box: TransportBox()
    )
    let stackAccessTokenProvider: @Sendable () async throws -> String = { "test-token" }
    let stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "test-token" }
    let rpcRequestTimeoutNanoseconds: UInt64 = 1_000_000_000
    let pairingRequestTimeoutNanoseconds: UInt64 = 1_000_000_000
    let supportedRouteKinds: [CmxAttachTransportKind] = [.iroh]
    let supportsServerPushEvents = false
    let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000) }

    var tunnelConnectProvider: MobileTunnelConnectProvider? {
        { [probe] request, _, _ in await probe.open(request) }
    }

    var tunnelListeningPortsProvider: MobileTunnelListeningPortsProvider? {
        { _ in MobileTunnelListeningPorts(ports: [:], allowsNonLoopbackHosts: false) }
    }
}
