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
        let stableKey = MacPairingKey(macDeviceID: "mac-a", instanceTag: "stable")
        let stable = fixture.shell.macBrowserNetwork(for: stableKey)
        #expect(stable === fixture.shell.macBrowserNetwork(for: stableKey))

        try fixture.select(instanceTag: "nightly")
        let nightly = fixture.shell.macBrowserNetwork(
            for: MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        )
        #expect(stable !== nightly)
        #expect(stable.registryOwner != nightly.registryOwner)
    }

    @Test func cachedBrowserRefusesLanesAfterSwitchingToSiblingInstance() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanDefaults() }
        try fixture.select(instanceTag: "stable")
        let stable = fixture.shell.macBrowserNetwork(
            for: MacPairingKey(macDeviceID: "mac-a", instanceTag: "stable")
        )
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

        // The cached browser remains usable when its own instance returns.
        try fixture.select(instanceTag: "stable", routeID: "stable-reconnected")
        let reconnected = try await stable.backend.open(host: "app.localhost", port: 5173)
        await reconnected.close()
        #expect(await fixture.probe.openedRoutes == ["stable", "stable-reconnected"])
    }

    @Test func availabilityRequiresTheExactInstanceIncludingLegacyPairings() throws {
        let fixture = try Fixture()
        defer { fixture.cleanDefaults() }
        let stable = MacPairingKey(macDeviceID: "mac-a", instanceTag: "stable")
        let nightly = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        let legacy = MacPairingKey(macDeviceID: "mac-a", instanceTag: nil)

        try fixture.select(instanceTag: "stable")
        #expect(fixture.shell.macBrowserTunnelAvailability(pairingKey: stable) == .available)
        #expect(fixture.shell.macBrowserTunnelAvailability(pairingKey: nightly) == .notConnected)
        #expect(fixture.shell.macBrowserTunnelAvailability(pairingKey: legacy) == .notConnected)
        #expect(fixture.shell.macBrowserTunnelAvailability(pairingKey: nil) == .notConnected)
        #expect(fixture.shell.macBrowserTunnelAvailability(
            pairingKey: MacPairingKey(macDeviceID: "mac-b", instanceTag: "stable")
        ) == .notConnected)

        fixture.shell.supportedHostCapabilities = []
        #expect(fixture.shell.macBrowserTunnelAvailability(pairingKey: stable) == .needsMacUpdate)
        #expect(fixture.shell.macBrowserTunnelAvailability(pairingKey: nightly) == .notConnected)
        fixture.shell.supportedHostCapabilities = [MobileShellComposite.macBrowserTunnelCapability]
        fixture.shell.activeRoute = nil
        #expect(fixture.shell.macBrowserTunnelAvailability(pairingKey: stable) == .routeWithoutLanes)

        try fixture.select(instanceTag: nil)
        #expect(fixture.shell.macBrowserTunnelAvailability(pairingKey: legacy) == .available)
        #expect(fixture.shell.macBrowserTunnelAvailability(pairingKey: stable) == .notConnected)
        #expect(fixture.shell.macBrowserNetwork(for: legacy).registryOwner == "mac:mac-a")
        fixture.shell.connectionState = .disconnected
        #expect(fixture.shell.macBrowserTunnelAvailability(pairingKey: legacy) == .notConnected)
    }

    @Test func canonicalIdentityReusesTheMatchingNetwork() throws {
        let fixture = try Fixture()
        defer { fixture.cleanDefaults() }
        let deviceID = UUID().uuidString
        try fixture.select(instanceTag: " stable ", macDeviceID: deviceID)
        let canonical = MacPairingKey(macDeviceID: deviceID.lowercased(), instanceTag: "stable")
        let alternate = MacPairingKey(macDeviceID: deviceID, instanceTag: " stable ")
        #expect(fixture.shell.macBrowserTunnelAvailability(pairingKey: canonical) == .available)
        #expect(fixture.shell.macBrowserNetwork(for: canonical) === fixture.shell.macBrowserNetwork(for: alternate))
    }

    @Test func preparingTheWrongInstanceDoesNotCreateANetwork() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanDefaults() }
        try fixture.select(instanceTag: "nightly")
        await #expect(throws: MobileTunnelOpenFailure.unavailable) {
            try await fixture.shell.prepareMacBrowserNetwork(
                pairingKey: MacPairingKey(macDeviceID: "mac-a", instanceTag: "stable"),
                loopbackPort: nil
            )
        }
        #expect(fixture.shell.macBrowserNetworks.isEmpty)
        #expect(await fixture.probe.listedRoutes.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func cachedBrowserDoesNotListSiblingInstancesPorts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanDefaults() }
        try fixture.select(instanceTag: "stable")
        let stable = fixture.shell.macBrowserNetwork(
            for: MacPairingKey(macDeviceID: "mac-a", instanceTag: "stable")
        )
        _ = try await stable.prepare(loopbackPort: 5173)
        try fixture.select(instanceTag: "nightly")
        _ = try await stable.prepare(loopbackPort: 5173)
        #expect(await fixture.probe.listedRoutes == ["stable"])
        await stable.stop()
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

        func select(instanceTag: String?, macDeviceID: String = "mac-a", routeID: String? = nil) throws {
            let route = try CmxAttachRoute(
                id: routeID ?? instanceTag ?? "legacy",
                kind: .iroh,
                endpoint: .peer(
                    identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                    pathHints: []
                ),
                priority: 0
            )
            shell.foregroundMacDeviceID = macDeviceID
            shell.activeMacInstanceTag = instanceTag
            shell.activeRoute = route
            shell.activeTicket = try CmxAttachTicket(
                workspaceID: "workspace-a",
                terminalID: "terminal-a",
                macDeviceID: macDeviceID,
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
    private(set) var listedRoutes: [String] = []

    func open(_ request: CmxByteTransportRequest) -> any MobileTunnelLaneConnection {
        openedRoutes.append(request.route.id)
        return EchoLane()
    }

    func list(_ request: CmxByteTransportRequest) -> MobileTunnelListeningPorts {
        listedRoutes.append(request.route.id)
        return MobileTunnelListeningPorts(ports: [:], allowsNonLoopbackHosts: false)
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
        { [probe] request in await probe.list(request) }
    }
}
