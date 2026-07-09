import CMUXMobileCore
import CmuxMobileRPC
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

        let firstTask = Task { @MainActor in
            await store.connectPairingURLResult(Self.qrURL)
        }
        await transport.waitForConnect()
        let secondTask = Task { @MainActor in
            await store.connectPairingURLResult(Self.qrURL)
        }
        let second = await Self.value(of: secondTask)
        let connectCountBeforeReleasingStuckConnect = await transport.connectCount()
        await transport.finishConnects()
        let first = await Self.value(of: firstTask)

        #expect(connectCountBeforeReleasingStuckConnect == 1)
        #expect(first == .failed || first == .superseded)
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
    }

    private static let qrURL = "cmux-ios://attach?v=2&pc=1&r=100.64.0.5:58465"

    private static func value<Value: Sendable>(
        of task: Task<Value, Never>,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async -> Value? {
        let latch = TaskValueTimeoutLatch()
        return await withCheckedContinuation { continuation in
            Task {
                let value = await task.value
                if await latch.tryResolve() {
                    continuation.resume(returning: value)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                if await latch.tryResolve() {
                    task.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private actor TaskValueTimeoutLatch {
        private var didResolve = false

        func tryResolve() -> Bool {
            guard !didResolve else { return false }
            didResolve = true
            return true
        }
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
