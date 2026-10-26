import CmuxNextCompat
import CmuxNextWakeups
import Testing

/// The per-launch idle wakeup histogram (`debug.energy`, p14-energy-008), fed through injected
/// uptime, interrupt wakeup and input counters.
@MainActor
@Suite struct IdleEnergyStatsTests {
    @Test func threeIdleMinutesAtAFifthPerSecondFallInTheQuarterBucket() throws {
        let counters = Counters()
        let monitor = IdleEnergyMonitor(sources: counters.sources)
        monitor.noteWake()
        for _ in 0..<3 {
            counters.advance(seconds: 60, wakeups: 12)
            monitor.noteWake()
        }
        let stats = monitor.stats
        #expect(stats.sampleCount == 3)
        let quarter = try #require(IdleEnergyStats.upperBounds.firstIndex(of: 0.25))
        #expect(stats.counts[quarter] == 3)
        #expect(IdleEnergyStats.label(ofBucket: quarter) == "0.25")
        #expect(stats.percentile(0.5) == 0.25)
        #expect(stats.percentile(0.99) == 0.25)
        #expect(stats.lastRate == 0.2)
    }

    @Test func aMinuteWithInputIsNotRecorded() {
        let counters = Counters()
        let monitor = IdleEnergyMonitor(sources: counters.sources)
        monitor.noteWake()
        counters.advance(seconds: 60, wakeups: 600, inputs: 1)
        monitor.noteWake()
        #expect(monitor.stats.sampleCount == 0)
        #expect(monitor.stats.windowsWithInput == 1)
        // The next window starts where the one with input ended.
        counters.advance(seconds: 60, wakeups: 6)
        monitor.noteWake()
        #expect(monitor.stats.sampleCount == 1)
        #expect(monitor.stats.counts[IdleEnergyStats.bucketIndex(0.1)] == 1)
    }

    @Test func wakesInsideTheWindowReadNoCounter() {
        let counters = Counters()
        let monitor = IdleEnergyMonitor(sources: counters.sources)
        monitor.noteWake()
        #expect(counters.wakeupReads == 1)
        for _ in 0..<59 {
            counters.advance(seconds: 1, wakeups: 1)
            monitor.noteWake()
        }
        #expect(counters.wakeupReads == 1, "only the uptime is read before the window is due")
        #expect(monitor.stats.sampleCount == 0)
    }

    /// No timer: time passing with no main run loop wake records nothing and reads nothing, and the
    /// first wake after it records one window over the whole span.
    @Test func recordingSchedulesNoTimer() {
        let counters = Counters()
        let monitor = IdleEnergyMonitor(sources: counters.sources)
        monitor.noteWake()
        counters.advance(seconds: 300, wakeups: 150)
        #expect(counters.wakeupReads == 1)
        #expect(counters.uptimeReads == 1)
        #expect(monitor.stats.sampleCount == 0)
        monitor.noteWake()
        #expect(monitor.stats.sampleCount == 1)
        #expect(monitor.stats.lastRate == 0.5)
    }

    @Test func bucketsArePinned() {
        #expect(IdleEnergyStats.upperBounds == [0, 0.1, 0.25, 0.5, 1, 2, 5, 10, 50])
        #expect(IdleEnergyStats.bucketIndex(0) == 0)
        #expect(IdleEnergyStats.bucketIndex(0.2) == 2)
        #expect(IdleEnergyStats.bucketIndex(50) == 8)
        #expect(IdleEnergyStats.bucketIndex(50.5) == 9)
        #expect(IdleEnergyStats.label(ofBucket: 9) == "50+")
        #expect(IdleEnergyStats.label(ofBucket: 4) == "1")
    }

    @Test func percentilesAreBucketUpperBoundsAndTheOverflowIsTheMax() {
        var stats = IdleEnergyStats()
        var reading = IdleEnergyStats.Reading(uptimeNanos: 0, interruptWakeups: 0, inputEvents: 0)
        stats.close(at: reading)
        // 99 windows at 0/s and one at 120/s, then a two-minute window at 1.5/s.
        for perSecond in Array(repeating: UInt64(0), count: 99) + [120] {
            reading.uptimeNanos += IdleEnergyStats.windowNanos
            reading.interruptWakeups += perSecond * 60
            stats.close(at: reading)
        }
        reading.uptimeNanos += IdleEnergyStats.windowNanos * 2
        reading.interruptWakeups += 180
        stats.close(at: reading)
        #expect(stats.sampleCount == 101)
        #expect(stats.percentile(0.5) == 0)
        #expect(stats.percentile(0.95) == 0)
        #expect(stats.percentile(0.99) == 2)
        #expect(stats.percentile(1) == 120)
        #expect(stats.maxRate == 120)
    }

    @Test func aCounterThatGoesBackIsNotASample() {
        var stats = IdleEnergyStats()
        stats.close(at: .init(uptimeNanos: 0, interruptWakeups: 100, inputEvents: 0))
        let rate = stats.close(at: .init(uptimeNanos: IdleEnergyStats.windowNanos, interruptWakeups: 10, inputEvents: 0))
        #expect(rate == nil)
        #expect(stats.sampleCount == 0)
        #expect(stats.percentile(0.5) == nil)
    }
}

/// Injected uptime, interrupt wakeups and input count, with how often each was read.
private final class Counters: Sendable {
    private struct State {
        var uptimeNanos: UInt64 = 1_000_000_000
        var wakeups: UInt64 = 0
        var inputs: UInt64 = 0
        var uptimeReads = 0
        var wakeupReads = 0
    }

    // Short critical sections from the sources' synchronous closures (lock carve-out, CLAUDE.md).
    private let state = Mutex(State())

    var uptimeReads: Int { state.withLock { $0.uptimeReads } }
    var wakeupReads: Int { state.withLock { $0.wakeupReads } }

    func advance(seconds: UInt64, wakeups: UInt64, inputs: UInt64 = 0) {
        state.withLock {
            $0.uptimeNanos += seconds * 1_000_000_000
            $0.wakeups += wakeups
            $0.inputs += inputs
        }
    }

    var sources: IdleEnergyMonitor.Sources {
        IdleEnergyMonitor.Sources(uptimeNanos: { [self] in readUptime() },
                                  interruptWakeups: { [self] in readWakeups() },
                                  inputEvents: { [self] in state.withLock { $0.inputs } })
    }

    private func readUptime() -> UInt64 {
        state.withLock { state in
            state.uptimeReads += 1
            return state.uptimeNanos
        }
    }

    private func readWakeups() -> UInt64? {
        state.withLock { state in
            state.wakeupReads += 1
            return state.wakeups
        }
    }
}
