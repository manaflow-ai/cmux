import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

struct LivenessManualAttachTicketResultFrame {
    var id: String?

    func make() throws -> Data {
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3600),
            authToken: "test-attach-token"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let ticketObject = try JSONSerialization.jsonObject(with: encoder.encode(ticket))
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": true,
            "result": ["ticket": ticketObject],
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }
}

// Test double protects its AsyncStream continuation behind a lock.
final class ManualReachability: ReachabilityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Void>.Continuation?

    var isOnline: Bool { get async { true } }

    var hasSubscriber: Bool {
        lock.withLock { continuation != nil }
    }

    func pathChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            lock.withLock {
                self.continuation = continuation
            }
        }
    }

    func emitPathChange() {
        let continuation: AsyncStream<Void>.Continuation? = lock.withLock { self.continuation }
        continuation?.yield(())
    }
}

@MainActor
func makeReconnectableConnectedStore(
    router: LivenessHostRouter,
    box: TransportBox,
    clock: TestClock,
    probeTimeoutNanoseconds: UInt64 = 200_000_000,
    reachability: any ReachabilityProviding = AlwaysOnlineReachability()
) async throws -> MobileShellComposite {
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: router, box: box),
        now: { clock.now },
        livenessProbeTimeoutNanoseconds: probeTimeoutNanoseconds
    )
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-liveness-\(UUID().uuidString).sqlite3")
    let pairedMacStore = try MobilePairedMacStore(databaseURL: databaseURL)
    let store = MobileShellComposite(
        runtime: runtime,
        pairedMacStore: pairedMacStore,
        identityProvider: StaticIdentityProvider(userID: "user-1"),
        reachability: reachability,
        deliveredNotificationClearer: NoopDeliveredNotificationClearer()
    )
    store.signIn()
    let ticket = try makeTicket(clock: clock)
    let connected = await store.connectPairingURL(try attachURL(for: ticket))
    #expect(connected, "scripted connect must succeed")
    return store
}
