import CmuxNextCompat
import CmuxNextWakeups
import CoreFoundation
import Testing

/// The per-launch idle wakeup histogram (`debug.energy`), fed through injected
/// uptime, interrupt wakeup and input counters and an injected wake registration. The app is idle
/// 60 s after its last input (and after launch); each sample is one window after that.
@MainActor
@Suite struct IdleEnergyStatsTests {
    @Test func threeIdleMinutesAtAFifthPerSecondFallInTheQuarterBucket() throws {
        let counters = Counters()
        let monitor = IdleEnergyMonitor(sources: counters.sources)
        Self.becomeIdle(monitor, counters)
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
        Self.becomeIdle(monitor, counters)
        counters.advance(seconds: 60, wakeups: 600, inputs: 1)
        monitor.noteWake()
        #expect(monitor.stats.sampleCount == 0)
        #expect(monitor.stats.windowsWithInput == 1)
        // Idle again 60 s after the wake that saw the input; the next window opens there.
        counters.advance(seconds: 60, wakeups: 300)
        monitor.noteWake()
        #expect(monitor.stats.sampleCount == 0)
        counters.advance(seconds: 60, wakeups: 6)
        monitor.noteWake()
        #expect(monitor.stats.sampleCount == 1)
        #expect(monitor.stats.lastRate == 0.1, "neither the input's minute nor the one after it is in the sample")
    }

    /// Input late in a window (59 s in) drops it: no sample at the 60 s mark, and the work the input
    /// started (its burst of wakeups) is never counted as idle.
    @Test func inputLateInAWindowRecordsNothingUntilTheAppIsIdleAgain() {
        let counters = Counters()
        let monitor = IdleEnergyMonitor(sources: counters.sources)
        Self.becomeIdle(monitor, counters)
        Self.tick(monitor, counters, seconds: 58)
        counters.advance(seconds: 1, wakeups: 0, inputs: 1)
        monitor.noteWake()
        // The input's animation and fetches wake the app hard just after it.
        counters.advance(seconds: 1, wakeups: 500)
        monitor.noteWake()
        #expect(monitor.stats.sampleCount == 0, "no sample at the 60 s mark: input arrived at 59 s")
        #expect(monitor.stats.windowsWithInput == 1)
        Self.tick(monitor, counters, seconds: 59 + 59)
        #expect(monitor.stats.sampleCount == 0, "119 s after the input: idle for 60 s, then 59 s of window")
        counters.advance(seconds: 1, wakeups: 6)
        monitor.noteWake()
        #expect(monitor.stats.sampleCount == 1, "one sample, a window after the app was idle again")
        #expect(monitor.stats.lastRate == 0.1, "the input's 500 wakeups are not in it")
    }

    @Test func inputBeforeTheAppIsIdleDropsNoWindowAndRestartsTheWait() {
        let counters = Counters()
        let monitor = IdleEnergyMonitor(sources: counters.sources)
        monitor.noteWake()
        for _ in 0..<20 {
            counters.advance(seconds: 5, wakeups: 1, inputs: 1)
            monitor.noteWake()
        }
        #expect(monitor.stats.windowsWithInput == 0, "no window was open")
        counters.advance(seconds: 59, wakeups: 0)
        monitor.noteWake()
        #expect(counters.wakeupReads == 0, "59 s after the last input the app is not idle yet")
        counters.advance(seconds: 1, wakeups: 0)
        monitor.noteWake()
        #expect(counters.wakeupReads == 1, "idle 60 s after the last input: the window opens")
        counters.advance(seconds: 60, wakeups: 0)
        monitor.noteWake()
        #expect(monitor.stats.sampleCount == 1)
        #expect(monitor.stats.lastRate == 0)
    }

    @Test func wakesReadTheWakeupCounterOnlyWhenAWindowOpensOrCloses() {
        let counters = Counters()
        let monitor = IdleEnergyMonitor(sources: counters.sources)
        monitor.noteWake()
        Self.tick(monitor, counters, seconds: 59)
        #expect(counters.wakeupReads == 0, "the app is not idle yet")
        Self.tick(monitor, counters, seconds: 1)
        #expect(counters.wakeupReads == 1, "the window opens")
        Self.tick(monitor, counters, seconds: 59)
        #expect(counters.wakeupReads == 1, "only the uptime and the input count are read inside the window")
        counters.advance(seconds: 1, wakeups: 0, inputs: 1)
        monitor.noteWake()
        #expect(counters.wakeupReads == 1, "a wake that sees input drops the window without reading it")
        #expect(monitor.stats.sampleCount == 0)
    }

    /// Time passing with no main run loop wake records nothing and reads nothing, and the first wake
    /// after it records one window over the whole span.
    @Test func timePassingWithoutAWakeReadsNothing() {
        let counters = Counters()
        let monitor = IdleEnergyMonitor(sources: counters.sources)
        Self.becomeIdle(monitor, counters)
        let uptimeReads = counters.uptimeReads
        counters.advance(seconds: 300, wakeups: 150)
        #expect(counters.wakeupReads == 1)
        #expect(counters.uptimeReads == uptimeReads)
        #expect(monitor.stats.sampleCount == 0)
        monitor.noteWake()
        #expect(monitor.stats.sampleCount == 1)
        #expect(monitor.stats.lastRate == 0.5)
    }

    /// Recording schedules no timer: `start()` adds one `afterWaiting` wake handler and nothing else,
    /// reads no counter, and a second call adds nothing; the handler is the only way the monitor runs.
    @Test func startRegistersOneAfterWaitingHandlerAndNoTimer() {
        let counters = Counters()
        let wakes = WakeRegistrations()
        let monitor = IdleEnergyMonitor(sources: counters.sources, observeWakes: wakes.register)
        #expect(wakes.activities.isEmpty, "the init registers nothing")
        monitor.start()
        monitor.start()
        #expect(wakes.activities == [.afterWaiting])
        #expect(counters.uptimeReads == 0, "start reads no counter: the first reading is at the first wake")
        wakes.fire()
        counters.advance(seconds: 60, wakeups: 0)
        wakes.fire()
        counters.advance(seconds: 60, wakeups: 12)
        wakes.fire()
        #expect(monitor.stats.sampleCount == 1, "the registered handler is the monitor's wake")
        #expect(wakes.activities == [.afterWaiting], "wakes register nothing more")
        monitor.stop()
        #expect(wakes.isReleased, "stop releases the handler's token")
        monitor.start()
        #expect(wakes.activities == [.afterWaiting, .afterWaiting])
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
        var uptime: UInt64 = 0
        var wakeups: UInt64 = 0
        stats.noteWake(at: uptime, inputEvents: 0) { wakeups }
        uptime += IdleEnergyStats.idleAfterNanos
        stats.noteWake(at: uptime, inputEvents: 0) { wakeups }
        // 99 windows at 0/s and one at 120/s, then a two-minute window at 1.5/s.
        for perSecond in Array(repeating: UInt64(0), count: 99) + [120] {
            uptime += IdleEnergyStats.windowNanos
            wakeups += perSecond * 60
            stats.noteWake(at: uptime, inputEvents: 0) { wakeups }
        }
        uptime += IdleEnergyStats.windowNanos * 2
        wakeups += 180
        stats.noteWake(at: uptime, inputEvents: 0) { wakeups }
        #expect(stats.sampleCount == 101)
        #expect(stats.percentile(0.5) == 0)
        #expect(stats.percentile(0.95) == 0)
        #expect(stats.percentile(0.99) == 2)
        #expect(stats.percentile(1) == 120)
        #expect(stats.maxRate == 120)
    }

    @Test func aCounterThatGoesBackIsNotASample() {
        var stats = IdleEnergyStats()
        stats.noteWake(at: 0, inputEvents: 0) { 100 }
        stats.noteWake(at: IdleEnergyStats.idleAfterNanos, inputEvents: 0) { 100 }
        let rate = stats.noteWake(at: IdleEnergyStats.idleAfterNanos + IdleEnergyStats.windowNanos, inputEvents: 0) { 10 }
        #expect(rate == nil)
        #expect(stats.sampleCount == 0)
        #expect(stats.percentile(0.5) == nil)
    }

    @Test func aClockThatGoesBackHasNotElapsed() {
        var stats = IdleEnergyStats()
        stats.noteWake(at: IdleEnergyStats.idleAfterNanos, inputEvents: 0) { 0 }
        var reads = 0
        stats.noteWake(at: 0, inputEvents: 0) {
            reads += 1
            return 0
        }
        #expect(reads == 0, "no window opens on a clock that went back")
    }

    /// One wake, then one 60 s later: the app is idle and a window is open.
    private static func becomeIdle(_ monitor: IdleEnergyMonitor, _ counters: Counters) {
        monitor.noteWake()
        counters.advance(seconds: 60, wakeups: 0)
        monitor.noteWake()
    }

    /// One wake a second for `seconds` seconds, with no input and no wakeups.
    private static func tick(_ monitor: IdleEnergyMonitor, _ counters: Counters, seconds: Int) {
        for _ in 0..<seconds {
            counters.advance(seconds: 1, wakeups: 0)
            monitor.noteWake()
        }
    }
}

/// The wake handlers a monitor registers, with the token each one returned.
@MainActor
private final class WakeRegistrations {
    private final class Token {}

    private(set) var activities: [CFRunLoopActivity] = []
    private var handler: (@MainActor () -> Void)?
    private weak var token: Token?

    var isReleased: Bool { token == nil }

    func register(_ activities: CFRunLoopActivity, _ onWake: @escaping @MainActor () -> Void) -> AnyObject {
        self.activities.append(activities)
        handler = onWake
        let token = Token()
        self.token = token
        return token
    }

    /// One main run loop wake.
    func fire() {
        handler?()
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
