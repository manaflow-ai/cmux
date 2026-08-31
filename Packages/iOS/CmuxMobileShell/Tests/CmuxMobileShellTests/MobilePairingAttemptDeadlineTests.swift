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
        // The relay default appends the synthesized relay route after the
        // ticket's loopback route, so the surfaced deadline failure is the
        // relay leg's hostless timeout copy, not the loopback address.
        #expect(store.connectionError == MobilePairingFailureCategory
            .handshakeTimedOut(host: nil, port: nil).message)
        #expect(store.connectionError?.contains("127.0.0.1") == false)
    }

    @Test func scannedOrPastedPairingInputUsesSameDeadline() async throws {
        let store = makeStore(pairingCode: try Self.pairingURL())

        await store.connectPairingInput()

        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError?.isEmpty == false)
        #expect(store.connectionError == MobilePairingFailureCategory
            .handshakeTimedOut(host: nil, port: nil).message)
        #expect(store.connectionError?.contains("127.0.0.1") == false)
    }

    @Test func immediatePairingRetryDoesNotStartSecondStuckConnect() async throws {
        let transport = CountingSlowIgnoringCancellationTransport()
        let runtime = PairingDeadlineRuntime(
            transportFactory: CountingSlowIgnoringCancellationTransportFactory(transport: transport)
        )
        let store = makeStore(runtime: runtime)

        // An anonymous ticket (no mac device id) cannot mint a relay session,
        // so the dial set is exactly the one stuck loopback route. That keeps
        // the connect count deterministic: a known-device ticket would also
        // dial the synthesized relay route on its own schedule.
        let pairingURL = try Self.pairingURL(macDeviceID: "")
        let first = await store.connectPairingURLResult(pairingURL)
        // The first attempt settles at the deadline while its dial task is
        // still being scheduled; the abandoned dial ignores cancellation and
        // reaches connect() on its own. Wait for it so the gating assertion
        // below races in neither direction.
        let firstDialStarted = try await pollUntil(attempts: 1000) {
            await transport.connectCount() == 1
        }
        let second = await store.connectPairingURLResult(pairingURL)
        let connectCount = await transport.connectCount()
        await transport.releaseStuckConnects()

        #expect(first == .failed)
        #expect(firstDialStarted)
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

    private static func pairingURL(macDeviceID: String = "deadline-mac") throws -> String {
        let route = try CmxAttachRoute(
            id: "deadline-loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58_465)
        )
        return try attachURL(for: CmxAttachTicket(
            workspaceID: "deadline-workspace",
            terminalID: nil,
            macDeviceID: macDeviceID,
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
