import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobilePairingAttemptDeadlineTests {
    @Test func qrPairingURLTimesOutWithoutWaitingForStuckTransport() async throws {
        let store = makeStore()
        let startedAt = Date()

        let result = await store.connectPairingURLResult(Self.qrURL)

        #expect(result == .failed)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError?.isEmpty == false)
        #expect(store.connectionError?.contains("100.64.0.5") == true)
        #expect(Date().timeIntervalSince(startedAt) < 0.05)
    }

    @Test func scannedOrPastedPairingInputUsesSameDeadline() async throws {
        let store = makeStore(pairingCode: Self.qrURL)
        let startedAt = Date()

        await store.connectPairingInput()

        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError?.isEmpty == false)
        #expect(store.connectionError?.contains("100.64.0.5") == true)
        #expect(Date().timeIntervalSince(startedAt) < 0.05)
    }

    private static let qrURL = "cmux-ios://attach?v=2&pc=1&r=100.64.0.5:58465"

    private func makeStore(pairingCode: String = "") -> MobileShellComposite {
        MobileShellComposite(
            runtime: PairingDeadlineRuntime(),
            isSignedIn: true,
            pairingCode: pairingCode,
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "pairing-deadline-\(UUID().uuidString)")!
        )
    }
}

private struct PairingDeadlineRuntime: MobileSyncRuntime {
    var transportFactory: any CmxByteTransportFactory = SlowIgnoringCancellationTransportFactory()
    var stackAccessTokenProvider: @Sendable () async throws -> String = { "test-stack-token" }
    var stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "test-stack-token" }
    var rpcRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var now: @Sendable () -> Date = { Date() }
    var supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale]
    var pairingRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var pairingAttemptTimeoutNanoseconds: UInt64 = 1_000_000
    var supportsServerPushEvents: Bool = false
}

private struct AlwaysOnlineReachability: ReachabilityProviding {
    var isOnline: Bool { get async { true } }

    func pathChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

private struct SlowIgnoringCancellationTransportFactory: CmxByteTransportFactory {
    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        SlowIgnoringCancellationTransport()
    }
}

private actor SlowIgnoringCancellationTransport: CmxByteTransport {
    func connect() async throws {
        let startedAt = Date()
        while Date().timeIntervalSince(startedAt) < 0.2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CmxNetworkByteTransportError.connectionTimedOut
    }

    func receive() async throws -> Data? {
        nil
    }

    func send(_ data: Data) async throws {}

    func close() async {}
}
