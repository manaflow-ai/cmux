import CmuxNextCompat
@testable import CmuxNextHostPressure
import os
import Testing

/// A memory pressure source the test drives, as the kernel's would: on the main actor, at once.
private final class DrivenPressureSource: MemoryPressureSource {
    private struct State {
        var deliver: (@MainActor @Sendable (MemoryPressureLevel) -> Void)?
        var level = MemoryPressureLevel.normal
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func start(delivering deliver: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void) {
        state.withLock { $0.deliver = deliver }
    }

    func cancel() {
        state.withLock { $0.deliver = nil }
    }

    /// The level last sent; normal before the first.
    var currentLevel: MemoryPressureLevel {
        state.withLock { $0.level }
    }

    /// Sets ``currentLevel`` and delivers `level`; nothing after ``cancel()``.
    @MainActor func send(_ level: MemoryPressureLevel) {
        let deliver = state.withLock { state in
            state.level = level
            return state.deliver
        }
        deliver?(level)
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
        let subscription = events.hostPressureSubscription { pressure in received.withLock { $0.append(pressure) } }
        #expect(subscription.current == .normal)

        source.send(.warning)
        source.send(.critical)
        source.send(.normal)
        #expect(received.withLock { $0 } == [.warn, .critical, .normal])

        subscription.end()
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

    /// A monitor started while the shared feed is already critical, with no change after it,
    /// reads critical: the level comes from the feed's `currentLevel`, not a sampler of its own.
    @Test func theMonitorStartsAtTheSharedEventsCurrentLevel() async {
        let source = DrivenPressureSource()
        let events = MemoryPressureEvents(source: source)
        source.send(.critical)
        let monitor = HostPressureMonitor(source: StaticHostSource(), memoryPressure: events.hostPressureSubscription, ticks: false)
        await monitor.start { _, _ in }
        await monitor.read()
        #expect(await monitor.level == .critical)
        #expect(await monitor.verdict?.pressure == .critical)
        await monitor.stop()
    }
}

/// A calm host: acpmux has no verdict, the local one is normal.
private struct StaticHostSource: HostPressureSource {
    func acpmuxVerdict() async -> HostBudgetVerdict? { nil }
    func localVerdict(pressure: HostMemoryPressure) async -> HostBudgetVerdict {
        HostBudgetVerdict(host: "gray", cores: 12, load1: 2, pressure: pressure, availableRAMFraction: 0.5, swapMBPerMin: 0)
    }
}
