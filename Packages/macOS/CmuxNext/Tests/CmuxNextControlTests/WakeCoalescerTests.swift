import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Timers that may run a little early ride a wake that already happened (``WakeCoalescer``), so four idle
/// checks no longer wake the app four times (app idle, 2026-11-25 on cmux20-bench: app.health.tick 0.22/s,
/// the starvation probe 0.20/s, BusyWatchdog's window 0.10/s and the daemon heartbeat 0.07/s, each its own wake).
@Suite(.timeLimit(.minutes(1)))
struct WakeCoalescerTests {
    /// The coalescer's clock: the manual clock's time in nanoseconds.
    static func coalescer(_ clock: ManualClock) -> WakeCoalescer {
        WakeCoalescer(now: { UInt64(clamping: clock.now.offset.components.seconds) * 1_000_000_000
            + UInt64(clamping: clock.now.offset.components.attoseconds / 1_000_000_000) })
    }

    static func reasons(_ ledger: WakeupLedger, _ owner: String) -> [String: UInt64] {
        Dictionary(ledger.snapshot().filter { $0.owner == owner }.map { ($0.reason, $0.count) }, uniquingKeysWith: +)
    }

    @Test func aTimerInsideItsEarlyWindowRunsOnAnotherWake() async throws {
        let clock = ManualClock()
        let coalescer = Self.coalescer(clock)
        let ledger = WakeupLedger()
        let timer = DemandTimer(owner: "rider", clock: clock, ledger: ledger, early: .seconds(5), coalescer: coalescer)
        let (fired, fire) = AsyncStream<Void>.makeStream()
        timer.schedule(after: .seconds(15)) { fire.yield() }
        try await clock.waitForSleeper()

        clock.advance(by: .seconds(9))
        coalescer.wake()
        #expect(timer.isScheduled, "9 s in: its window opens at 10 s")

        clock.advance(by: .seconds(1))
        coalescer.wake()
        #expect(!timer.isScheduled, "a wake inside its window runs it")
        for await _ in fired { break }
        #expect(Self.reasons(ledger, "rider") == ["coalesced": 1], "it rode a wake: no deadline wake of its own")

        clock.advance(by: .seconds(10))
        coalescer.wake()
        #expect(Self.reasons(ledger, "rider") == ["coalesced": 1], "it runs once")
    }

    @Test func aTimerWithNoEarlyWindowWaitsForItsDeadline() async throws {
        let clock = ManualClock()
        let coalescer = Self.coalescer(clock)
        let ledger = WakeupLedger()
        let timer = DemandTimer(owner: "exact", clock: clock, ledger: ledger, coalescer: coalescer)
        timer.schedule(after: .seconds(5)) {}
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(4))
        coalescer.wake()
        #expect(timer.isScheduled)
        #expect(Self.reasons(ledger, "exact").isEmpty)
    }

    @Test func aDeadlineThatFiresIsAWakeTheOthersRide() async throws {
        let clock = ManualClock()
        let coalescer = Self.coalescer(clock)
        let ledger = WakeupLedger()
        let driver = DemandTimer(owner: "driver", clock: clock, ledger: ledger, coalescer: coalescer)
        let rider = DemandTimer(owner: "rider", clock: clock, ledger: ledger, early: .seconds(5), coalescer: coalescer)
        let (rode, ride) = AsyncStream<Void>.makeStream()
        rider.schedule(after: .seconds(8)) { ride.yield() }
        try await clock.waitForSleeper()
        driver.schedule(after: .seconds(5)) {}
        while clock.sleeperDeadlines.count < 2 { await Task.yield() }
        clock.advance(by: .seconds(5))
        for await _ in rode { break }
        #expect(Self.reasons(ledger, "driver") == ["deadline": 1])
        #expect(Self.reasons(ledger, "rider") == ["coalesced": 1], "3 s early, on the driver's wake")
    }

    @Test func aCancelledOrMovedTimerDoesNotRide() async throws {
        let clock = ManualClock()
        let coalescer = Self.coalescer(clock)
        let ledger = WakeupLedger()
        let timer = DemandTimer(owner: "moved", clock: clock, ledger: ledger, early: .seconds(5), coalescer: coalescer)
        timer.schedule(after: .seconds(6)) {}
        timer.schedule(after: .seconds(30)) {}
        clock.advance(by: .seconds(2))
        coalescer.wake()
        #expect(timer.isScheduled, "moved to 30 s: its window opens at 25 s")
        timer.cancel()
        clock.advance(by: .seconds(30))
        coalescer.wake()
        #expect(Self.reasons(ledger, "moved").isEmpty)
    }

    @Test func aRideAndItsOwnDeadlineRunItOnce() async throws {
        let clock = ManualClock()
        let coalescer = Self.coalescer(clock)
        let ledger = WakeupLedger()
        let timer = DemandTimer(owner: "once", clock: clock, ledger: ledger, early: .seconds(5), coalescer: coalescer)
        let runs = Runs()
        timer.schedule(after: .seconds(10)) { runs.add() }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(10))
        coalescer.wake()
        for _ in 0..<50 { await Task.yield() }
        #expect(Self.reasons(ledger, "once").values.reduce(0, +) == 1, "one claim, whichever came first")
        #expect(runs.count == 1)
    }
}

private nonisolated final class Runs: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func add() { value.withLock { $0 += 1 } }
}
