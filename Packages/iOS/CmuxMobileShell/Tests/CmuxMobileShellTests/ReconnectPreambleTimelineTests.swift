import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

/// Cold-launch preamble timeline: the stretch between the stored-Mac reconnect
/// claim and the first dial, measured on the real `MobileShellComposite` path
/// with a real SQLite paired-Mac store and a scripted transport.
///
/// On the phone this stretch measured ~1.3s with no mark explaining it. This
/// test pins the structural cost (serialized awaits, store reads, executor
/// hops) per commit so a regression is caught headlessly instead of being
/// rediscovered by a device launch, and separates it from environmental cost
/// (radio, TLS, first-frame contention) that only the device marks can see:
/// if this passes in milliseconds while the device shows seconds, the device
/// timeline names which stage absorbs the environment.
@MainActor
extension ReconnectRouteSelectionTests {
    static let expectedColdLaunchPreambleStages = [
        "claim",
        "attempt-entry",
        "scope-snapshot",
        "backup-refresh-spawned",
        "store-reads",
        "capabilities-seeded",
        "hidden-ids",
        "candidates-ready n=1",
        "dial-start c0",
    ]

    /// A tripwire, not the gate: the structural cost measures ~4ms, but under
    /// a parallel full-suite run on a loaded host this path was observed at
    /// 710ms, so a tight bound only measures the host. The deterministic gate
    /// is `ReconnectColdLaunchRestoreGateTests` (gated fake backup); this bound
    /// catches only a stall on the order of the device symptom (~1300ms).
    static let coldLaunchPreambleDialBoundMilliseconds = 1_000.0

    @Test func coldLaunchPreambleReachesFirstDialWithinBound() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = DialInstantRecordingTransportFactory(
            base: RouteRecordingTransportFactory(
                router: router,
                box: box,
                failingPorts: []
            )
        )
        let store = try await makeReconnectStore(
            routes: [try loopback(51002)],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.debugLoopback]
            )
        )

        let calledAt = ContinuousClock.now
        let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")

        #expect(connected)
        let stages = store.storedMacReconnectPreambleStages
        let timeline = stages
            .map { "\($0.name)=+\(String(format: "%.1f", $0.offsetMilliseconds))ms" }
            .joined(separator: " ")
        // Printed on every run so the measured structural cost survives in
        // the test log next to the bound, the way the raw-channel benchmark
        // number does.
        print("cold-launch preamble timeline: \(timeline)")
        #expect(
            stages.map(\.name) == Self.expectedColdLaunchPreambleStages,
            "preamble stages: \(timeline)"
        )
        #expect(stages.allSatisfy { $0.generation == store.storedMacReconnectGeneration })
        #expect(stages.map(\.offset) == stages.map(\.offset).sorted(), "offsets are monotonic: \(timeline)")
        let dialStart = try #require(stages.last)
        #expect(
            dialStart.offsetMilliseconds < Self.coldLaunchPreambleDialBoundMilliseconds,
            "claim→dial-start exceeded bound: \(timeline)"
        )
        // Call→transport-dial covers everything the phone journal would show
        // between the reconnect entry and its own dial event, including the
        // connect(ticket:) interior after the last preamble mark.
        let transportDialAt = try #require(factory.recordedFirstDialInstant())
        let callToTransportDial = transportDialAt - calledAt
        let callToTransportDialMs = Double(callToTransportDial.components.seconds) * 1_000
            + Double(callToTransportDial.components.attoseconds) / 1e15
        print("cold-launch call→transport-dial: \(String(format: "%.1f", callToTransportDialMs))ms")
        #expect(
            callToTransportDialMs < Self.coldLaunchPreambleDialBoundMilliseconds,
            "call→transport-dial exceeded bound: \(String(format: "%.1f", callToTransportDialMs))ms; \(timeline)"
        )
    }

    @Test func retryStartsAFreshPreambleTimeline() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: box,
            failingPorts: []
        )
        let store = try await makeReconnectStore(
            routes: [try loopback(51003)],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.debugLoopback]
            )
        )
        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        let firstGeneration = store.storedMacReconnectGeneration
        #expect(store.storedMacReconnectPreambleStages.first?.generation == firstGeneration)

        store.disconnectLiveConnection()
        _ = await store.retryActiveMacReconnect(stackUserID: "user-1")

        let stages = store.storedMacReconnectPreambleStages
        #expect(store.storedMacReconnectGeneration > firstGeneration)
        #expect(stages.first?.name == "claim")
        #expect(stages.allSatisfy { $0.generation == store.storedMacReconnectGeneration })
    }
}

/// Wraps a transport factory and records the `ContinuousClock` instant of the
/// first `makeTransport` call: the moment the composite actually dials. The
/// preamble's last mark (`dial-start`) is taken before `connect(ticket:)`; the
/// distance from that mark to this instant is the connect interior (route
/// registry admission, transport-queue drain), which the device journal
/// reports separately and this measurement pins headlessly.
final class DialInstantRecordingTransportFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let base: any CmxByteTransportFactory
    private let lock = NSLock()
    private var firstDialAt: ContinuousClock.Instant?

    init(base: any CmxByteTransportFactory) {
        self.base = base
    }

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        lock.withLock {
            if firstDialAt == nil { firstDialAt = ContinuousClock.now }
        }
        return try base.makeTransport(for: route)
    }

    func recordedFirstDialInstant() -> ContinuousClock.Instant? {
        lock.withLock { firstDialAt }
    }
}
