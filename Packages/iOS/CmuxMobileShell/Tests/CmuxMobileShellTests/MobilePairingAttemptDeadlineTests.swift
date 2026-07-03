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
            transportFactory: CountingSlowIgnoringCancellationTransportFactory(transport: transport)
        )
        let store = makeStore(runtime: runtime)

        let first = await store.connectPairingURLResult(Self.qrURL)
        let second = await store.connectPairingURLResult(Self.qrURL)

        #expect(first == .failed)
        #expect(second == .failed)
        #expect(await transport.connectCount() == 1)
        #expect(store.connectionState == .disconnected)
    }

    @Test func mixedTrustedAndUntrustedRoutesStillConnectOverTrustedRoute() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now },
            supportedRouteKinds: [.tailscale, .manualHost]
        )
        let store = makeStore(runtime: runtime)
        let trustedRoute = try CmxAttachRoute(
            id: "a-trusted-tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 58_465),
            priority: 0
        )
        let manualFallbackRoute = try CmxAttachRoute(
            id: "b-manual-fallback",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: 58_465),
            priority: 1
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [trustedRoute, manualFallbackRoute],
            expiresAt: clock.now.addingTimeInterval(3600)
        )

        let result = await store.connectPairingURLResult(try attachURL(for: ticket))

        #expect(result == .connected)
        #expect(store.connectionState == .connected)
        #expect(store.manualHostTrustWarning == nil)
        #expect(store.selectedWorkspace?.id.rawValue == "live-workspace")
    }

    @Test func manualFallbackPromptsOnlyAfterTrustedRouteFails() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: ManualFallbackApprovalTransportFactory(router: router, box: box),
            now: { clock.now },
            supportedRouteKinds: [.tailscale, .manualHost]
        )
        let store = makeStore(runtime: runtime)
        let trustedRoute = try CmxAttachRoute(
            id: "a-trusted-tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 58_465),
            priority: 0
        )
        let manualFallbackRoute = try CmxAttachRoute(
            id: "b-manual-fallback",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: 58_465),
            priority: 1
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [trustedRoute, manualFallbackRoute],
            expiresAt: clock.now.addingTimeInterval(3600)
        )

        let result = await store.connectPairingURLResult(try attachURL(for: ticket))

        #expect(result == .needsUserApproval)
        #expect(store.connectionState != .connected)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.77:58465")
        #expect(await router.count(of: "workspace.list") == 0)

        let approvedResult = await store.acceptManualHostTrustWarning()

        #expect(approvedResult == .connected)
        #expect(store.connectionState == .connected)
        #expect(store.manualHostTrustWarning == nil)
        #expect(store.selectedWorkspace?.id.rawValue == "live-workspace")
        #expect(await router.count(of: "workspace.list") >= 1)
    }

    private static let qrURL = "cmux-ios://attach?v=2&pc=1&r=100.64.0.5:58465"

    private func makeStore(
        runtime: any MobileSyncRuntime = PairingDeadlineRuntime(),
        pairingCode: String = "",
        manualHostTrustStore: any MobileManualHostTrustStoring = InMemoryMobileManualHostTrustStore()
    ) -> MobileShellComposite {
        MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairingCode: pairingCode,
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "pairing-deadline-\(UUID().uuidString)")!,
            manualHostTrustStore: manualHostTrustStore
        )
    }
}

private struct ManualFallbackApprovalTransportFactory: CmxByteTransportFactory {
    let router: LivenessHostRouter
    let box: TransportBox

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        if route.kind == .tailscale {
            return SlowIgnoringCancellationTransport()
        }
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }
}
