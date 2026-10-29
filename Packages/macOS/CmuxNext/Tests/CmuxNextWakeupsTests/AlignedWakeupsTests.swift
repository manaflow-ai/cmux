import CmuxNextCompat
@testable import CmuxNextWakeups
import Testing

/// AlignedWakeups: one wake per boundary bucket (1 s hidden, 8 ms flexible), hidden
/// deadlines only at their whole second, precise deadlines exact, and the timer parked when every deadline
/// is cancelled. The deadlines go through a real MainWakeUpQueue on WakeUpQueueRig; the test fires the
/// timer itself.
@MainActor
@Suite("AlignedWakeupsTests")
struct AlignedWakeupsTests {
    nonisolated private static let ms: UInt64 = 1_000_000

    @Test("50 hidden deadlines in one second share one wake at the whole second, in deadline order")
    func fiftyHiddenDeadlinesOneWake() {
        let rig = WakeUpQueueRig(start: 10_000 * Self.ms + 1)
        let log = AlignedLog()
        for index in 0..<50 {
            rig.wakeups.schedule(owner: "hidden", after: .milliseconds(19 * index + 1), placement: .hidden) {
                log.ran.append(index)
            }
        }
        #expect(rig.wakeups.pendingCount == 50)
        #expect(rig.timer.armedDate == 11_000 * Self.ms, "no wake before the next whole second")
        rig.fire()
        #expect(log.ran == Array(0..<50))
        #expect(rig.fires == 1)
        #expect(rig.wakeups.pendingCount == 0)
        #expect(rig.timer.armedDate == nil, "nothing left: the timer is parked")
    }

    @Test("20 flexible deadlines in one 8 ms bucket share one wake")
    func twentyFlexibleDeadlinesOneWake() {
        let rig = WakeUpQueueRig()
        let log = AlignedLog()
        // 17 ms ... 23.65 ms all snap up to the 24 ms tick.
        for index in 0..<20 {
            rig.wakeups.schedule(owner: "flexible", after: .microseconds(17_000 + 350 * index), placement: .flexible) {
                log.ran.append(index)
            }
        }
        #expect(rig.timer.armedDate == 24 * Self.ms)
        rig.fire()
        #expect(log.ran == Array(0..<20))
        #expect(rig.fires == 1)
    }

    @Test("Flexible deadlines in two buckets wake twice")
    func flexibleTwoBuckets() {
        let rig = WakeUpQueueRig()
        let log = AlignedLog()
        rig.wakeups.schedule(owner: "a", after: .milliseconds(3)) { log.ran.append(3) }
        rig.wakeups.schedule(owner: "b", after: .milliseconds(8)) { log.ran.append(8) }
        rig.wakeups.schedule(owner: "c", after: .milliseconds(9)) { log.ran.append(9) }
        #expect(rig.timer.armedDate == 8 * Self.ms)
        rig.fire()
        #expect(log.ran == [3, 8])
        #expect(rig.timer.armedDate == 16 * Self.ms, "9 ms snaps to the 16 ms tick")
        rig.fire()
        #expect(log.ran == [3, 8, 9])
        #expect(rig.fires == 2)
    }

    @Test("Precise deadlines fire at their own instants with no tolerance")
    func preciseIsExact() {
        let start = 1_000 * Self.ms + 123
        let rig = WakeUpQueueRig(start: start)
        let log = AlignedLog()
        rig.wakeups.schedule(owner: "five", after: .milliseconds(5), placement: .precise) { log.ran.append(5) }
        rig.wakeups.schedule(owner: "seven", after: .milliseconds(7), placement: .precise) { log.ran.append(7) }
        #expect(rig.timer.arms.last == FakeWakeUpTimer.Arm(date: start + 5 * Self.ms, tolerance: 0))
        rig.fire()
        #expect(log.ran == [5])
        #expect(rig.timer.arms.last == FakeWakeUpTimer.Arm(date: start + 7 * Self.ms, tolerance: 0))
        rig.fire()
        #expect(log.ran == [5, 7])
        #expect(rig.fires == 2)
    }

    @Test("A precise deadline of 36 ms or more is flexible")
    func longPreciseIsFlexible() {
        let rig = WakeUpQueueRig()
        rig.wakeups.schedule(owner: "long", after: .milliseconds(41), placement: .precise) {}
        #expect(rig.timer.armedDate == 48 * Self.ms)
    }

    @Test("Cancelling every deadline of a bucket parks the timer")
    func cancelAllParks() {
        let rig = WakeUpQueueRig()
        let log = AlignedLog()
        let tickets = (0..<5).map { index in
            rig.wakeups.schedule(owner: "hidden", after: .milliseconds(100 * index + 50), placement: .hidden) {
                log.ran.append(index)
            }
        }
        #expect(rig.timer.armedDate == 1_000 * Self.ms)
        for ticket in tickets.dropLast() { #expect(rig.wakeups.cancel(ticket)) }
        #expect(rig.timer.armedDate == 1_000 * Self.ms, "one deadline still holds the bucket")
        #expect(rig.wakeups.cancel(tickets[4]))
        #expect(rig.timer.armedDate == nil)
        #expect(rig.timer.parks == 1)
        #expect(rig.wakeups.pendingCount == 0)
        #expect(!rig.wakeups.cancel(tickets[4]), "a second cancel finds nothing")
        #expect(log.ran.isEmpty)
    }

    @Test("A hidden and a flexible deadline on one boundary share one wake")
    func hiddenAndFlexibleShare() {
        let rig = WakeUpQueueRig()
        let log = AlignedLog()
        rig.wakeups.schedule(owner: "hidden", after: .milliseconds(400), placement: .hidden) { log.ran.append(400) }
        rig.wakeups.schedule(owner: "flexible", after: .milliseconds(995)) { log.ran.append(995) }
        #expect(rig.timer.armedDate == 1_000 * Self.ms)
        rig.fire()
        #expect(Set(log.ran) == [400, 995])
        #expect(rig.fires == 1)
    }

    @Test("A due hidden deadline waits for its whole second, not an earlier visible fire; a re-arm waits a second")
    func hiddenWaitsForItsSecond() {
        let rig = WakeUpQueueRig()
        let log = AlignedLog()
        let wakeups = rig.wakeups
        wakeups.schedule(owner: "hidden", after: .milliseconds(400), placement: .hidden) {
            log.ran.append(400)
            wakeups.schedule(owner: "hidden", after: .milliseconds(10), placement: .hidden) { log.ran.append(1_010) }
            wakeups.schedule(owner: "flexible", after: .milliseconds(20)) { log.ran.append(1_020) }
        }
        wakeups.schedule(owner: "flexible", after: .milliseconds(500)) { log.ran.append(500) }
        #expect(rig.timer.armedDate == 504 * Self.ms)
        rig.fire()
        #expect(log.ran == [500], "the hidden 400 ms deadline does not ride the visible fire")
        #expect(rig.timer.armedDate == 1_000 * Self.ms)
        rig.fire()
        #expect(log.ran == [500, 400])
        #expect(rig.timer.armedDate == 1_024 * Self.ms)
        rig.fire()
        #expect(log.ran == [500, 400, 1_020], "the re-armed hidden deadline skips the visible fire at 1024 ms")
        #expect(rig.timer.armedDate == 2_000 * Self.ms)
        rig.fire()
        #expect(log.ran == [500, 400, 1_020, 1_010])
        #expect(rig.fires == 4)
        #expect(rig.timer.armedDate == nil)
    }

    @Test("A due entry behind a top that is not due runs in that top's fire, with no wake of its own")
    func dueEntryBehindNotDueTop() {
        let start = 10_000 * Self.ms
        let rig = WakeUpQueueRig(start: start)
        let log = AlignedLog()
        rig.wakeups.schedule(owner: "three", after: .milliseconds(3)) { log.ran.append(3) }
        // Due from 5 ms on, but its latest time (105 ms) is behind the 9 ms entry's (17 ms).
        rig.queue.insert(owner: "five", at: start + 5 * Self.ms, window: .window(delay: .seconds(1))) { log.ran.append(5) }
        rig.wakeups.schedule(owner: "nine", after: .milliseconds(9)) { log.ran.append(9) }
        #expect(rig.timer.armedDate == start + 8 * Self.ms)
        rig.fire()
        #expect(log.ran == [3], "the top (9 ms) is not due at 8 ms, so the due 5 ms entry behind it waits")
        #expect(rig.timer.arms.last == FakeWakeUpTimer.Arm(date: start + 16 * Self.ms, tolerance: 1 * Self.ms),
                "the tolerance is the top's latest time (17 ms) minus the fire time (16 ms)")
        rig.fire()
        #expect(log.ran == [3, 9, 5])
        #expect(rig.fires == 2)
    }

    @Test("Hidden windows: the next whole second, never sooner; zero delay is exact")
    func hiddenWindows() {
        let rig = WakeUpQueueRig()
        rig.wakeups.schedule(owner: "long", after: .milliseconds(2_500), placement: .hidden) {}
        #expect(rig.timer.armedDate == 3_000 * Self.ms)
        rig.wakeups.schedule(owner: "now", after: .zero, placement: .hidden) {}
        #expect(rig.timer.armedDate == 0)

        let window = WakeLeeway.hidden(delay: .milliseconds(1_001))
        #expect(window.fireTime(deadline: 1_001 * Self.ms) == 2_000 * Self.ms)
        #expect(window.fireTime(deadline: 2_000 * Self.ms) == 2_000 * Self.ms)
        #expect(window.tolerance == AlignedWakeups.hiddenInterval)
        #expect(WakeLeeway.hidden(delay: .zero).policy == .precise)
    }

    @Test("DemandTimer sleeps with WakeLeeway's tolerance by default and an explicit one when given")
    func demandTimerPassesTolerance() async {
        let clock = ToleranceClock()
        let timer = DemandTimer(owner: "test", clock: clock, ledger: WakeupLedger())
        let cases: [(delay: Duration, tolerance: Duration?)] = [(.milliseconds(50), nil), (.seconds(2), nil), (.milliseconds(50), .zero)]
        for item in cases {
            let fired = FiredOnce()
            timer.schedule(after: item.delay, tolerance: item.tolerance) { @MainActor in fired.fire() }
            await fired.wait()
        }
        #expect(clock.tolerances == [.milliseconds(8), .milliseconds(200), .zero])
    }
}

extension WakeUpQueueRig {
    /// The placement layer on the rig's queue.
    var wakeups: AlignedWakeups { AlignedWakeups(queue: queue) }
}

@MainActor
private final class AlignedLog {
    var ran: [Int] = []
}

/// A one-shot signal the DemandTimer test awaits instead of polling.
@MainActor
private final class FiredOnce {
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func fire() {
        fired = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !fired else { return }
        await withCheckedContinuation { waiter = $0 }
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
