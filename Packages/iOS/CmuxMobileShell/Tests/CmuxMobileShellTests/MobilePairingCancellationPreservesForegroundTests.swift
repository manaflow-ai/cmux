import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobilePairingCancellationPreservesForegroundTests {
    @Test func cancelInFlightPairingKeepsExistingConnection() async throws {
        let clock = TestClock()
        let oldRouter = LivenessHostRouter()
        let oldBox = TransportBox()
        let transport = CountingSlowIgnoringCancellationTransport()
        let runtime = PairingDeadlineRuntime(
            transportFactory: CountingSlowIgnoringCancellationTransportFactory(transport: transport),
            pairingAttemptTimeoutNanoseconds: 30 * 1_000_000_000
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "pairing-cancel-\(UUID().uuidString)")!
        )
        try installFreshLivenessRemoteClient(on: store, router: oldRouter, box: oldBox, clock: clock)
        let originalClient = try #require(store.remoteClient)

        let pairingURL = try attachURL(for: makeTicket(clock: clock))
        let pairing = Task { @MainActor in
            await store.connectPairingURLResult(pairingURL)
        }
        await transport.waitUntilConnectStarted()
        store.cancelPairing()
        await transport.releaseStuckConnects()
        _ = await pairing.value

        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === originalClient)
    }

    @Test func cancelPairingBeforeAuthorizedResponseKeepsExistingConnection() async throws {
        let clock = TestClock()
        let oldRouter = LivenessHostRouter()
        let oldBox = TransportBox()
        let newRouter = LivenessHostRouter()
        let newBox = TransportBox()
        let tokenProvider = BlockingAccountSwitchTokenProvider()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: newRouter, box: newBox),
            stackAccessTokenProvider: { try await tokenProvider.tokenIgnoringCancellation() },
            now: { clock.now },
            supportedRouteKinds: [.debugLoopback],
            supportsServerPushEvents: false
        )
        let store = makeConnectedStore(runtime: runtime)
        try installFreshLivenessRemoteClient(on: store, router: oldRouter, box: oldBox, clock: clock)
        let originalClient = try #require(store.remoteClient)

        let pairingURL = try attachURL(for: makeTicket(clock: clock))
        let pairing = Task { @MainActor in
            await store.connectPairingURLResult(pairingURL)
        }
        await tokenProvider.waitUntilRequested()
        store.cancelPairing()
        await tokenProvider.release(with: "authorized-token")
        let result = await pairing.value

        #expect(result == .superseded)
        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === originalClient)
    }

    @Test func cancelPairingDuringPairedMacLookupDoesNotActivateCandidate() async throws {
        let clock = TestClock()
        let oldRouter = LivenessHostRouter()
        let oldBox = TransportBox()
        let newRouter = LivenessHostRouter()
        let newBox = TransportBox()
        let oldRoute = try CmxAttachRoute(
            id: "old-loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_583)
        )
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    MobilePairedMac(
                        macDeviceID: "old-mac",
                        displayName: "Old Mac",
                        routes: [oldRoute],
                        createdAt: clock.now,
                        lastSeenAt: clock.now,
                        isActive: true,
                        stackUserID: "test-user",
                        teamID: "team-a"
                    ),
                ],
            ],
            blockedTeams: ["team-a"]
        )
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: newRouter, box: newBox),
            now: { clock.now },
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "test-user"),
            teamIDProvider: { "team-a" },
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "pairing-cancel-persistence-\(UUID().uuidString)")!
        )
        try installFreshLivenessRemoteClient(on: store, router: oldRouter, box: oldBox, clock: clock)
        store.setWorkspaceStatesForTesting([:], foregroundMacDeviceID: "old-mac")
        let originalClient = try #require(store.remoteClient)
        let ticket = try makeTicket(clock: clock)
        let url = try attachURL(for: ticket)

        let pairing = Task { @MainActor in
            await store.connectPairingURLResult(url)
        }
        await pairedMacStore.waitUntilLoadStarted(teamID: "team-a")
        store.cancelPairing()
        await pairedMacStore.release(teamID: "team-a")
        let result = await pairing.value

        #expect(result == .superseded)
        #expect(await pairedMacStore.currentUpsertCount() == 0)
        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === originalClient)
    }

    @Test func cancelPairingDuringPairedMacUpsertKeepsPreviousMacActive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let innerStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let clock = TestClock()
        let oldRoute = try CmxAttachRoute(
            id: "old-loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_583)
        )
        try await innerStore.upsert(
            macDeviceID: "old-mac",
            displayName: "Old Mac",
            routes: [oldRoute],
            markActive: true,
            stackUserID: "test-user",
            teamID: nil,
            now: clock.now
        )
        let gatedStore = GatedUpsertStore(inner: innerStore)
        let oldRouter = LivenessHostRouter()
        let oldBox = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: LivenessHostRouter(),
                box: TransportBox()
            ),
            now: { clock.now },
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: gatedStore,
            identityProvider: StaticIdentityProvider(userID: "test-user"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "pairing-cancel-upsert-\(UUID().uuidString)")!
        )
        try installFreshLivenessRemoteClient(on: store, router: oldRouter, box: oldBox, clock: clock)
        store.setWorkspaceStatesForTesting([:], foregroundMacDeviceID: "old-mac")
        let originalClient = try #require(store.remoteClient)
        let ticket = try makeTicket(clock: clock)
        let url = try attachURL(for: ticket)

        let pairing = Task { @MainActor in
            await store.connectPairingURLResult(url)
        }
        await gatedStore.waitUntilUpsertEntered()
        store.cancelPairing()
        await gatedStore.release()
        let result = await pairing.value
        let activeMac = try await gatedStore.activeMac(
            stackUserID: "test-user",
            teamID: nil
        )

        #expect(result == .superseded)
        #expect(activeMac?.macDeviceID == "old-mac")
        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === originalClient)
    }

    private func makeConnectedStore(runtime: any MobileSyncRuntime) -> MobileShellComposite {
        MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            identityProvider: StaticIdentityProvider(userID: "test-user"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "pairing-cancel-\(UUID().uuidString)")!
        )
    }
}
