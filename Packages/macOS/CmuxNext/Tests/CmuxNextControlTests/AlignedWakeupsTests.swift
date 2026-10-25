import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// AlignedWakeups: one sleep per boundary bucket (1 s hidden, 8 ms flexible), precise deadlines exact, and
/// the bucket's sleep cancelled with its last deadline (plans/cmux-next/chrome-parity/p06-scheduler.md, 012).
@MainActor @Suite(.timeLimit(.minutes(1))) struct AlignedWakeupsTests {
    /// The deadlines that ran, in order; a test awaits a count instead of polling.
    @MainActor private final class Fired {
        private(set) var names: [String] = []
        private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

        func record(_ name: String) {
            names.append(name)
            if let waiter, names.count >= waiter.count {
                self.waiter = nil
                waiter.continuation.resume()
            }
        }

        func wait(for count: Int) async {
            guard names.count < count else { return }
            await withCheckedContinuation { waiter = (count, $0) }
        }
    }

    /// The ticket a deadline's action cancels, set after both are scheduled.
    @MainActor private final class TicketBox {
        var ticket: AlignedWakeups.Ticket?
    }

    private static func wakeups(_ ledger: WakeupLedger, _ owner: String) -> UInt64 {
        ledger.snapshot().filter { $0.owner == owner }.reduce(0) { $0 + $1.count }
    }

    @Test func fiftyHiddenDeadlinesInOneSecondShareOneWakeup() async throws {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let wakeups = AlignedWakeups(owner: "test", clock: clock, ledger: ledger)
        let fired = Fired()
        for index in 0..<50 {
            wakeups.schedule(owner: "hidden \(index)", after: .milliseconds(19 * index + 1), alignment: .hidden) {
                fired.record("hidden \(index)")
            }
        }
        #expect(wakeups.sleepCount == 1)
        #expect(wakeups.pendingCount == 50)
        try await clock.waitForSleeper()
        #expect(clock.sleeperCount == 1)

        clock.advance(by: .milliseconds(999))
        #expect(fired.names.isEmpty, "a hidden deadline runs no sooner than its 1 s boundary")
        clock.advance(by: .milliseconds(1))
        await fired.wait(for: 50)
        #expect(fired.names == (0..<50).map { "hidden \($0)" }, "deadline order within the bucket")
        #expect(Self.wakeups(ledger, "test.aligned") == 1)
        #expect(wakeups.sleepCount == 0)
        #expect(wakeups.pendingCount == 0)
    }

    @Test func twentyFlexibleDeadlinesInOneEightMillisecondBucketShareOneWakeup() async throws {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let wakeups = AlignedWakeups(owner: "test", clock: clock, ledger: ledger)
        let fired = Fired()
        // 17 ms ... 23.65 ms all snap up to the 24 ms boundary.
        for index in 0..<20 {
            wakeups.schedule(owner: "flexible", after: .microseconds(17_000 + 350 * index), alignment: .flexible) {
                fired.record("flexible \(index)")
            }
        }
        #expect(wakeups.sleepCount == 1)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(23))
        #expect(fired.names.isEmpty)
        clock.advance(by: .milliseconds(1))
        await fired.wait(for: 20)
        #expect(fired.names.count == 20)
        #expect(Self.wakeups(ledger, "test.aligned") == 1)
    }

    @Test func flexibleDeadlinesInTwoBucketsWakeTwice() async throws {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let wakeups = AlignedWakeups(owner: "test", clock: clock, ledger: ledger)
        let fired = Fired()
        wakeups.schedule(owner: "a", after: .milliseconds(3), alignment: .flexible) { fired.record("a") }
        wakeups.schedule(owner: "b", after: .milliseconds(8), alignment: .flexible) { fired.record("b") }
        wakeups.schedule(owner: "c", after: .milliseconds(9), alignment: .flexible) { fired.record("c") }
        #expect(wakeups.sleepCount == 2, "3 and 8 ms snap to 8 ms; 9 ms snaps to 16 ms")
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(8))
        await fired.wait(for: 2)
        #expect(fired.names == ["a", "b"])
        clock.advance(by: .milliseconds(8))
        await fired.wait(for: 3)
        #expect(fired.names == ["a", "b", "c"])
        #expect(Self.wakeups(ledger, "test.aligned") == 2)
    }

    @Test func preciseDeadlinesAreExact() async throws {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let wakeups = AlignedWakeups(owner: "test", clock: clock, ledger: ledger)
        let fired = Fired()
        wakeups.schedule(owner: "five", after: .milliseconds(5), alignment: .precise) { fired.record("five") }
        wakeups.schedule(owner: "seven", after: .milliseconds(7), alignment: .precise) { fired.record("seven") }
        #expect(wakeups.sleepCount == 2, "precise deadlines are not bucketed")
        try await clock.waitForSleeper()

        clock.advance(by: .milliseconds(5))
        await fired.wait(for: 1)
        #expect(fired.names == ["five"], "a precise deadline runs at 5 ms, not at the 8 ms boundary")
        clock.advance(by: .milliseconds(2))
        await fired.wait(for: 2)
        #expect(fired.names == ["five", "seven"])
        #expect(Self.wakeups(ledger, "test.precise") == 2)
        #expect(Self.wakeups(ledger, "test.aligned") == 0)
    }

    @Test func cancellingEveryDeadlineCancelsTheBucket() async throws {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let wakeups = AlignedWakeups(owner: "test", clock: clock, ledger: ledger)
        let fired = Fired()
        let tickets = (0..<5).map { index in
            wakeups.schedule(owner: "hidden", after: .milliseconds(100 * index + 50), alignment: .hidden) {
                fired.record("hidden \(index)")
            }
        }
        try await clock.waitForSleeper()
        #expect(clock.sleeperCount == 1)

        for ticket in tickets.dropLast() { wakeups.cancel(ticket) }
        #expect(wakeups.sleepCount == 1, "one deadline still holds the bucket")
        #expect(clock.sleeperCount == 1)
        wakeups.cancel(tickets[4])
        #expect(!wakeups.isPending(tickets[4]))
        #expect(wakeups.sleepCount == 0)
        #expect(clock.sleeperCount == 0, "the bucket's sleep is cancelled")

        // A later deadline proves the cancelled ones never run when their boundary passes.
        wakeups.schedule(owner: "later", after: .seconds(2), alignment: .flexible) { fired.record("later") }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(2))
        await fired.wait(for: 1)
        #expect(fired.names == ["later"])
        #expect(Self.wakeups(ledger, "test.aligned") == 1)
    }

    @Test func anActionCanCancelALaterDeadlineOfItsBucket() async throws {
        let clock = ManualClock()
        let wakeups = AlignedWakeups(owner: "test", clock: clock, ledger: WakeupLedger())
        let fired = Fired()
        let second = TicketBox()
        wakeups.schedule(owner: "first", after: .milliseconds(1), alignment: .flexible) {
            fired.record("first")
            if let ticket = second.ticket { wakeups.cancel(ticket) }
        }
        second.ticket = wakeups.schedule(owner: "second", after: .milliseconds(2), alignment: .flexible) { fired.record("second") }
        wakeups.schedule(owner: "third", after: .milliseconds(3), alignment: .flexible) { fired.record("third") }
        #expect(wakeups.sleepCount == 1)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(8))
        await fired.wait(for: 2)
        #expect(fired.names == ["first", "third"])
    }

    @Test func hiddenAndFlexibleDeadlinesOnOneInstantShareASleep() async throws {
        let clock = ManualClock()
        let ledger = WakeupLedger()
        let wakeups = AlignedWakeups(owner: "test", clock: clock, ledger: ledger)
        let fired = Fired()
        wakeups.schedule(owner: "hidden", after: .milliseconds(400), alignment: .hidden) { fired.record("hidden") }
        wakeups.schedule(owner: "flexible", after: .milliseconds(995), alignment: .flexible) { fired.record("flexible") }
        #expect(wakeups.sleepCount == 1, "both snap to the 1 s instant")
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        await fired.wait(for: 2)
        #expect(fired.names == ["hidden", "flexible"])
        #expect(Self.wakeups(ledger, "test.aligned") == 1)
    }

    @Test func anEmptyInstanceHasNoSleep() {
        let clock = ManualClock()
        let wakeups = AlignedWakeups(owner: "test", clock: clock, ledger: WakeupLedger())
        #expect(wakeups.sleepCount == 0)
        #expect(clock.sleeperCount == 0)
    }

    @Test func boundariesSnapUpAndNeverEarlier() {
        #expect(AlignedWakeups.Alignment.flexible.boundary(of: .zero) == .zero)
        #expect(AlignedWakeups.Alignment.flexible.boundary(of: .nanoseconds(1)) == .milliseconds(8))
        #expect(AlignedWakeups.Alignment.flexible.boundary(of: .milliseconds(8)) == .milliseconds(8))
        #expect(AlignedWakeups.Alignment.hidden.boundary(of: .milliseconds(1_001)) == .seconds(2))
        #expect(AlignedWakeups.Alignment.precise.boundary(of: .microseconds(4_321)) == .microseconds(4_321))
    }

    @Test func demandTimerPassesItsTolerance() async throws {
        let clock = ToleranceClock()
        let timer = DemandTimer(owner: "test", clock: clock, ledger: WakeupLedger())
        let fired = Fired()
        timer.schedule(after: .milliseconds(50), tolerance: AlignedWakeups.leeway) { @MainActor in fired.record("timer") }
        await fired.wait(for: 1)
        #expect(clock.tolerances == [AlignedWakeups.leeway])
    }
}

/// A clock whose sleeps return at once and record the tolerance they were given.
private final class ToleranceClock: Clock, Sendable {
    private let base = ContinuousClock()
    private let recorded = Mutex<[Duration?]>([])

    var tolerances: [Duration?] { recorded.withLock { $0 } }
    var now: ContinuousClock.Instant { base.now }
    var minimumResolution: Duration { base.minimumResolution }

    @concurrent func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        recorded.withLock { $0.append(tolerance) }
    }
}
