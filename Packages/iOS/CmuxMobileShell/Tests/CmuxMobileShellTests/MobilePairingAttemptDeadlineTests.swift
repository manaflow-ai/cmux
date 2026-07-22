import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobilePairingAttemptDeadlineTests {
    @Test func qrPairingURLTimesOutWithoutWaitingForStuckTransport() async throws {
        let store = makeStore()

        let result = await store.connectPairingURLResult(try Self.pairingURL())

        #expect(result == .failed)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError?.isEmpty == false)
        #expect(store.connectionError?.contains("127.0.0.1") == true)
    }

    @Test func scannedOrPastedPairingInputUsesSameDeadline() async throws {
        let store = makeStore(pairingCode: try Self.pairingURL())

        await store.connectPairingInput()

        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError?.isEmpty == false)
        #expect(store.connectionError?.contains("127.0.0.1") == true)
    }

    @Test func immediatePairingRetryDoesNotStartSecondStuckConnect() async throws {
        let transport = CountingSlowIgnoringCancellationTransport()
        let runtime = PairingDeadlineRuntime(
            transportFactory: CountingSlowIgnoringCancellationTransportFactory(transport: transport)
        )
        let store = makeStore(runtime: runtime)

        let pairingURL = try Self.pairingURL()
        let first = await store.connectPairingURLResult(pairingURL)
        let second = await store.connectPairingURLResult(pairingURL)
        let connectCount = await transport.connectCount()
        await transport.releaseStuckConnects()

        #expect(first == .failed)
        #expect(second == .failed)
        #expect(connectCount == 1)
        #expect(store.connectionState == .disconnected)
    }

    @Test func mixedTrustedAndUntrustedRoutesStillConnectOverTrustedRoute() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now },
            supportedRouteKinds: [.debugLoopback, .tailscale]
        )
        let store = makeStore(runtime: runtime)
        let trustedRoute = try CmxAttachRoute(
            id: "a-trusted-loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58_465),
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
    }

    @Test func hostStatusUsesOnlyTheRemainingPairingAttemptBudget() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        await router.setWorkspaceListResponseHook {
            clock.advance(by: 2)
        }
        var runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now }
        )
        runtime.pairingAttemptTimeoutNanoseconds = 1_000_000_000
        let store = makeStore(runtime: runtime)

        let result = await store.connectPairingURLResult(
            try attachURL(for: makeTicket(clock: clock))
        )

        #expect(result == .failed)
        #expect(await router.count(of: "workspace.list") == 1)
        #expect(await router.count(of: "mobile.host.status") == 0)
        #expect(store.connectionState == .disconnected)
    }

    private static func pairingURL() throws -> String {
        let route = try CmxAttachRoute(
            id: "deadline-loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58_465)
        )
        return try attachURL(for: CmxAttachTicket(
            workspaceID: "deadline-workspace",
            terminalID: nil,
            macDeviceID: "deadline-mac",
            macDisplayName: "Deadline Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [route],
            expiresAt: Date().addingTimeInterval(60)
        ))
    }

    private func makeStore(
        runtime: any MobileSyncRuntime = PairingDeadlineRuntime(),
        pairingCode: String = ""
    ) -> MobileShellComposite {
        MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairingCode: pairingCode,
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "pairing-deadline-\(UUID().uuidString)")!
        )
    }
}
