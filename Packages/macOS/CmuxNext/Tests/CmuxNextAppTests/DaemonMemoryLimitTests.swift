@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextMemory
import CmuxNextWakeups
import Foundation
import Testing

/// The app tells the local daemon its memory limit on each change: the coordinator hands the
/// link each level and mode, each connection of the store is told the current limit once, a repeat is no
/// change, and a daemon without `memory-limit-v1` is skipped (cmux-tui-core server/memory_limit.rs answers
/// `memory.limit`).
@MainActor @Suite(.serialized) struct DaemonMemoryLimitTests {
    /// What the fake daemon received. The follower sends from its pump off main, so a test awaits the count
    /// it expects instead of draining main turns.
    @MainActor final class Received {
        var requests: [MemoryLimitRequest] = [] {
            didSet { resumeWaiter() }
        }
        private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

        /// Returns once `count` requests arrived.
        func reach(_ count: Int) async {
            guard requests.count < count else { return }
            await withCheckedContinuation { waiter = (count, $0) }
        }

        private func resumeWaiter() {
            guard let waiter, requests.count >= waiter.count else { return }
            self.waiter = nil
            waiter.continuation.resume()
        }
    }

    /// Keeps release slices and never runs them: the link releases nothing.
    final class HeldSlices: MemoryReleaseSlicer {
        func scheduleSlice(_ slice: @escaping @MainActor () -> Void) {}
    }

    /// A main-thread scheduler with no display link: a post runs on the next main run loop pass.
    private static func work() -> MainWorkScheduler {
        MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in nil }
    }

    private static let normal = MemoryLimitRequest(level: .normal, mode: .medium)
    private static let critical = MemoryLimitRequest(level: .critical, mode: .medium)

    @Test func edgesOnlyWhileConnectedAndEveryConnectionIsToldOnce() {
        var edges = DaemonMemoryLimitEdges(Self.normal)
        #expect(edges.observe(Self.critical, connected: false) == nil, "nobody to tell while down")
        #expect(edges.connected() == Self.critical)
        #expect(edges.observe(Self.critical, connected: true) == nil, "a repeat is no change")
        let aggressive = MemoryLimitRequest(level: .critical, mode: .aggressive)
        #expect(edges.observe(aggressive, connected: true) == aggressive, "a mode change is a change")
        edges.disconnected()
        #expect(edges.told == nil)
        #expect(edges.connected() == aggressive, "a restarted daemon holds no limit of the app's")
    }

    @Test func requestLineSpellsTheDaemonsFields() throws {
        let held = try line(MemoryLimitRequest(level: .warning, mode: .aggressive, pressureOverride: .warning))
        #expect(held["cmd"] as? String == "memory.limit")
        #expect(held["level"] as? String == "warning")
        #expect(held["mode"] as? String == "aggressive")
        #expect(held["override"] as? String == "warning")
        let plain = try line(Self.normal)
        #expect(plain["override"] == nil, "no override: the field is left out")
        #expect(MemoryLimitRequest.requiredCapability == "memory-limit-v1")
        #expect(DaemonCapability.memoryLimit.tier == .optional, "the bundled daemon serves it")
    }

    /// The coordinator's level, its debug override and its mode each reach the connected daemon once, through
    /// the link registered as one of its consumers; a daemon without the capability hears nothing.
    @Test(.timeLimit(.minutes(1))) func coordinatorChangesReachTheConnectedDaemon() async {
        let kernel = ManualMemoryPressureSource()
        let pressure = MemoryPressureEvents(source: kernel)
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: HeldSlices())
        let store = DaemonStore()
        let daemon = Received()
        let follow = DaemonMemoryLimitFollow(AppMemoryConsumers.memoryLimit(of: coordinator), store: store, on: Self.work()) {
            daemon.requests.append($0)
        }
        let link = DaemonMemoryLimitLink(
            follow: follow, registry: coordinator, observeOverrides: { coordinator.observePressureOverride($0) }
        ) { AppMemoryConsumers.memoryLimit(of: coordinator) }
        #expect(coordinator.report(budget: .forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false)).consumers
            .contains { $0.name == DaemonMemoryLimitLink.name })

        let identity = DaemonIdentity(capabilities: [MemoryLimitRequest.capability], generation: "boot")
        _ = store.apply(.connected(identity, generationChanged: true))
        await drainMainTurns()
        await daemon.reach(1)
        #expect(daemon.requests == [Self.normal], "a new connection is told the limit the app holds")

        kernel.send(.critical)
        await daemon.reach(2)
        #expect(daemon.requests.last == Self.critical)

        // An override equal to the kernel's level keeps the level, and still reaches the daemon, set and cleared.
        coordinator.pressureOverride = .critical
        await daemon.reach(3)
        #expect(coordinator.level == .critical)
        #expect(daemon.requests.last == MemoryLimitRequest(level: .critical, mode: .medium, pressureOverride: .critical))
        coordinator.pressureOverride = nil
        await daemon.reach(4)
        #expect(daemon.requests.last == Self.critical)

        coordinator.pressureOverride = .warning
        await daemon.reach(5)
        #expect(daemon.requests.last == MemoryLimitRequest(level: .warning, mode: .medium, pressureOverride: .warning))

        coordinator.mode = .aggressive
        await daemon.reach(6)
        #expect(daemon.requests.last == MemoryLimitRequest(level: .warning, mode: .aggressive, pressureOverride: .warning))

        // A daemon without `memory-limit-v1` is skipped.
        store.apply(.disconnected(reason: "handoff"))
        _ = store.apply(.connected(DaemonIdentity(generation: "older"), generationChanged: true))
        await drainMainTurns()
        coordinator.pressureOverride = nil
        await drainMainTurns()
        #expect(daemon.requests.count == 6)
        withExtendedLifetime((link, pressure)) {}
    }

    private func line(_ request: MemoryLimitRequest) throws -> [String: Any] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
