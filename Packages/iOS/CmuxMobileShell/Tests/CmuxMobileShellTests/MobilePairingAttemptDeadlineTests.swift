import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobilePairingAttemptDeadlineTests {
    @Test func qrPairingURLTimesOutWithoutWaitingForStuckTransport() async throws {
        let store = makeStore()

        let result = await store.connectPairingURLResult(Self.qrURL)

        #expect(result == .failed)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError?.isEmpty == false)
        #expect(store.connectionError?.contains("100.64.0.5") == true)
        #expect(store.pairingChecklist.network.status == .failed)
        #expect(store.pairingChecklist.network.message?.contains("100.64.0.5") == true)
        #expect(store.pairingChecklist.authentication.status == .pending)
        #expect(store.pairingChecklist.trust.status == .succeeded)
    }

    // The v2 QR carries a bare tailscale route, but this build advertises only
    // `.iroh` support, so route selection finds nothing it can dial and fails at
    // `.routeSelection`: no route is ever dialed, so the network gate is never
    // proven. `connect()` records the failure with `.routeSelection` (network stays
    // pending); the generic connect-failure recorder must not reclassify it as a
    // `.connect`-phase failure and paint the network row succeeded for a route
    // that was never dialed.
    @Test func noSupportedRoutePairingDoesNotClaimNetworkSucceeded() async throws {
        let runtime = PairingDeadlineRuntime(supportedRouteKinds: [.iroh])
        let store = makeStore(runtime: runtime)

        let result = await store.connectPairingURLResult(Self.qrURL)

        #expect(result == .failed)
        #expect(store.connectionState == .disconnected)
        #expect(store.pairingChecklist.network.status == .pending)
        #expect(store.pairingChecklist.authentication.status == .pending)
        #expect(store.pairingChecklist.trust.status == .failed)
    }

    @Test func scannedOrPastedPairingInputUsesSameDeadline() async throws {
        let store = makeStore(pairingCode: Self.qrURL)

        await store.connectPairingInput()

        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError?.isEmpty == false)
        #expect(store.connectionError?.contains("100.64.0.5") == true)
    }

    @Test func immediatePairingRetryDoesNotStartSecondStuckConnect() async throws {
        let transport = CountingSlowIgnoringCancellationTransport()
        let runtime = PairingDeadlineRuntime(
            transportFactory: CountingSlowIgnoringCancellationTransportFactory(transport: transport),
            pairingAttemptTimeoutNanoseconds: 500_000_000
        )
        let store = makeStore(runtime: runtime)

        let firstTask = Task {
            await store.connectPairingURLResult(Self.qrURL)
        }
        await transport.waitForConnectCount(1)
        let first = await firstTask.value
        let second = await store.connectPairingURLResult(Self.qrURL)

        #expect(first == .failed)
        #expect(second == .failed)
        #expect(await transport.connectCount() == 1)
        #expect(store.connectionState == .disconnected)
        await transport.releaseConnects()
    }

    @Test func mixedTrustedAndUntrustedRoutesStillConnectOverTrustedRoute() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now },
            supportedRouteKinds: [.tailscale]
        )
        let store = makeStore(runtime: runtime)
        let trustedRoute = try CmxAttachRoute(
            id: "a-trusted-tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 58_465),
            priority: 0
        )
        let untrustedRoute = try CmxAttachRoute(
            id: "b-public-fallback",
            kind: .tailscale,
            endpoint: .hostPort(host: "203.0.113.10", port: 58_465),
            priority: 1
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [trustedRoute, untrustedRoute],
            expiresAt: clock.now.addingTimeInterval(3600)
        )

        let result = await store.connectPairingURLResult(try attachURL(for: ticket))

        #expect(result == .connected)
        #expect(store.connectionState == .connected)
        #expect(store.selectedWorkspace?.id.rawValue == "live-workspace")
        #expect(store.pairingChecklist.steps.map(\.status) == [.succeeded, .succeeded, .succeeded])
    }

    // `shutdown()` runs from the reversible SwiftUI `onDisappear`. A store seeded
    // `.connected` models a live session whose hosting view just disappeared. The
    // bug: `shutdown()` nilled `remoteClient` but left `connectionState == .connected`,
    // so a SwiftUI-reused store reported connected with no transport, and the
    // reconnect-on-appear gate (`shouldReconnectStoredMac`, gated on
    // `connectionState != .connected`) never re-dialed. `shutdown()` must leave the
    // store consistently disconnected.
    @Test func shutdownLeavesConnectedStoreConsistentlyDisconnected() {
        let store = makeStore(connectionState: .connected)
        #expect(store.connectionState == .connected)
        #expect(store.macConnectionStatus == .connected)

        store.shutdown()

        #expect(store.connectionState == .disconnected)
        #expect(store.macConnectionStatus == .unavailable)
    }

    @Test func shutdownResetsInFlightPairingChecklist() async {
        let transport = CountingSlowIgnoringCancellationTransport()
        let runtime = PairingDeadlineRuntime(
            transportFactory: CountingSlowIgnoringCancellationTransportFactory(transport: transport)
        )
        let store = makeStore(runtime: runtime)

        let pairingTask = Task {
            await store.connectPairingURLResult(Self.qrURL)
        }
        await transport.waitForConnectCount(1)
        #expect(store.pairingChecklist == .inProgress)

        store.shutdown()
        #expect(store.pairingChecklist == .idle)

        await transport.releaseConnects()
        let result = await pairingTask.value
        #expect(result == .superseded)
        #expect(store.connectionState == .disconnected)
        #expect(store.pairingChecklist == .idle)
    }

    private static let qrURL = "cmux-ios://attach?v=2&pc=1&r=100.64.0.5:58465"

    private func makeStore(
        runtime: any MobileSyncRuntime = PairingDeadlineRuntime(),
        pairingCode: String = "",
        connectionState: MobileConnectionState = .disconnected
    ) -> MobileShellComposite {
        MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: connectionState,
            pairingCode: pairingCode,
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "pairing-deadline-\(UUID().uuidString)")!
        )
    }
}
