import CmuxNextCompat
@testable import CmuxNextHostPressure
import os
import Testing

/// A memory pressure source the test drives, as the kernel's would: on the main actor, at once.
private final class DrivenPressureSource: MemoryPressureSource {
    private let deliver = OSAllocatedUnfairLock<(@MainActor @Sendable (MemoryPressureLevel) -> Void)?>(initialState: nil)

    func start(delivering deliver: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void) {
        self.deliver.withLock { $0 = deliver }
    }

    func cancel() {
        deliver.withLock { $0 = nil }
    }

    @MainActor func send(_ level: MemoryPressureLevel) {
        deliver.withLock { $0 }?(level)
    }
}

/// The monitor's memory pressure comes from the app's one ``MemoryPressureEvents``
/// (`hostPressureSubscription`): each level reaches the subscriber in the host budget's words, and
/// ending the subscription stops the calls.
@MainActor struct HostPressureMemoryFeedTests {
    @Test func eachLevelReachesTheMonitorUntilTheSubscriptionEnds() {
        let source = DrivenPressureSource()
        let events = MemoryPressureEvents(source: source)
        let received = OSAllocatedUnfairLock<[HostMemoryPressure]>(initialState: [])
        let end = events.hostPressureSubscription { pressure in received.withLock { $0.append(pressure) } }

        source.send(.warning)
        source.send(.critical)
        source.send(.normal)
        #expect(received.withLock { $0 } == [.warn, .critical, .normal])

        end()
        source.send(.critical)
        #expect(received.withLock { $0 } == [.warn, .critical, .normal])
    }

    /// The monitor itself, on the real events: a kernel-style level change reaches its level.
    @Test func theMonitorFollowsTheSharedEvents() async {
        let source = DrivenPressureSource()
        let events = MemoryPressureEvents(source: source)
        let monitor = HostPressureMonitor(source: StaticHostSource(), memoryPressure: events.hostPressureSubscription, ticks: false)
        let (stream, continuation) = AsyncStream<HostPressureLevel>.makeStream()
        var levels = stream.makeAsyncIterator()
        await monitor.start { level, _ in continuation.yield(level) }
        await monitor.read()
        source.send(.critical)
        #expect(await levels.next() == .critical)
        await monitor.stop()
    }
}

/// A calm host: acpmux has no verdict, the local one is normal.
private struct StaticHostSource: HostPressureSource {
    func acpmuxVerdict() async -> HostBudgetVerdict? { nil }
    func localVerdict() async -> HostBudgetVerdict {
        HostBudgetVerdict(host: "gray", cores: 12, load1: 2, pressure: .normal, availableRAMFraction: 0.5, swapMBPerMin: 0)
    }
}
