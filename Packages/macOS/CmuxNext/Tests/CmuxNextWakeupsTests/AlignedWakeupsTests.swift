import CmuxNextCompat
@testable import CmuxNextWakeups
import Testing

/// AlignedWakeups (p06-scheduler-012): one wake per boundary bucket (1 s hidden, 8 ms flexible), precise
/// deadlines exact, and the timer parked when every deadline is cancelled. The deadlines go through a real
/// MainWakeUpQueue with a fake timer and a fake uptime; the test fires the timer itself.
@MainActor
@Suite("AlignedWakeupsTests")
struct AlignedWakeupsTests {
    nonisolated private static let ms: UInt64 = 1_000_000

    @Test("50 hidden deadlines in one second share one wake at the whole second, in deadline order")
    func fiftyHiddenDeadlinesOneWake() {
        let rig = AlignedRig(start: 10_000 * Self.ms + 1)
        let log = AlignedLog()
        for index in 0..<50 {
            rig.wakeups.schedule(owner: "hidden", after: .milliseconds(19 * index + 1), alignment: .hidden) {
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
        let rig = AlignedRig()
        let log = AlignedLog()
        // 17 ms ... 23.65 ms all snap up to the 24 ms tick.
        for index in 0..<20 {
            rig.wakeups.schedule(owner: "flexible", after: .microseconds(17_000 + 350 * index), alignment: .flexible) {
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
        let rig = AlignedRig()
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
        let rig = AlignedRig(start: start)
        let log = AlignedLog()
        rig.wakeups.schedule(owner: "five", after: .milliseconds(5), alignment: .precise) { log.ran.append(5) }
        rig.wakeups.schedule(owner: "seven", after: .milliseconds(7), alignment: .precise) { log.ran.append(7) }
        #expect(rig.timer.arms.last == AlignedFakeTimer.Arm(date: start + 5 * Self.ms, tolerance: 0))
        rig.fire()
        #expect(log.ran == [5])
        #expect(rig.timer.arms.last == AlignedFakeTimer.Arm(date: start + 7 * Self.ms, tolerance: 0))
        rig.fire()
        #expect(log.ran == [5, 7])
        #expect(rig.fires == 2)
    }

    @Test("A precise deadline of 36 ms or more is flexible")
    func longPreciseIsFlexible() {
        let rig = AlignedRig()
        rig.wakeups.schedule(owner: "long", after: .milliseconds(41), alignment: .precise) {}
        #expect(rig.timer.armedDate == 48 * Self.ms)
    }

    @Test("Cancelling every deadline of a bucket parks the timer")
    func cancelAllParks() {
        let rig = AlignedRig()
        let log = AlignedLog()
        let tickets = (0..<5).map { index in
            rig.wakeups.schedule(owner: "hidden", after: .milliseconds(100 * index + 50), alignment: .hidden) {
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
        let rig = AlignedRig()
        let log = AlignedLog()
        rig.wakeups.schedule(owner: "hidden", after: .milliseconds(400), alignment: .hidden) { log.ran.append(400) }
        rig.wakeups.schedule(owner: "flexible", after: .milliseconds(995)) { log.ran.append(995) }
        #expect(rig.timer.armedDate == 1_000 * Self.ms)
        rig.fire()
        #expect(Set(log.ran) == [400, 995])
        #expect(rig.fires == 1)
    }

    @Test("A due hidden deadline runs in an earlier fire instead of adding a wake")
    func dueHiddenJoinsEarlierFire() {
        let rig = AlignedRig()
        let log = AlignedLog()
        rig.wakeups.schedule(owner: "hidden", after: .milliseconds(400), alignment: .hidden) { log.ran.append(400) }
        rig.wakeups.schedule(owner: "flexible", after: .milliseconds(500)) { log.ran.append(500) }
        #expect(rig.timer.armedDate == 504 * Self.ms)
        rig.fire()
        #expect(log.ran == [500, 400], "the smaller latest time runs first")
        #expect(rig.fires == 1)
        #expect(rig.timer.armedDate == nil)
    }

    @Test("Hidden windows: the next whole second, never sooner; zero delay is exact")
    func hiddenWindows() {
        let rig = AlignedRig()
        rig.wakeups.schedule(owner: "long", after: .milliseconds(2_500), alignment: .hidden) {}
        #expect(rig.timer.armedDate == 3_000 * Self.ms)
        rig.wakeups.schedule(owner: "now", after: .zero, alignment: .hidden) {}
        #expect(rig.timer.armedDate == 0)

        let window = WakeLeeway.hidden(delay: .milliseconds(1_001))
        #expect(window.fireTime(deadline: 1_001 * Self.ms) == 2_000 * Self.ms)
        #expect(window.fireTime(deadline: 2_000 * Self.ms) == 2_000 * Self.ms)
        #expect(window.tolerance == AlignedWakeups.hiddenInterval)
        #expect(WakeLeeway.hidden(delay: .zero).policy == .precise)
    }

    @Test("DemandTimer passes its tolerance to the clock's sleep")
    func demandTimerPassesTolerance() async {
        let clock = ToleranceClock()
        let timer = DemandTimer(owner: "test", clock: clock, ledger: WakeupLedger())
        let fired = FiredOnce()
        let tolerance = WakeLeeway.window(delay: .milliseconds(50)).tolerance
        timer.schedule(after: .milliseconds(50), tolerance: tolerance) { @MainActor in fired.fire() }
        await fired.wait()
        #expect(clock.tolerances == [tolerance])
    }
}

/// AlignedWakeups on a MainWakeUpQueue with a fake timer, a fake uptime and its own ledger.
@MainActor
private struct AlignedRig {
    let timer = AlignedFakeTimer()
    let uptime: AlignedFakeUptime
    let ledger = WakeupLedger(uptime: { 0 })
    let queue: MainWakeUpQueue
    let wakeups: AlignedWakeups

    init(start: UInt64 = 0) {
        let timer = timer, uptime = AlignedFakeUptime(start)
        self.uptime = uptime
        queue = MainWakeUpQueue(alignment: WakeLeeway.defaultAlignment, ledger: ledger, uptime: { uptime.now }) { _ in timer }
        wakeups = AlignedWakeups(queue: queue)
    }

    /// Moves the uptime to the armed date and runs the timer's callout.
    func fire() {
        if let date = timer.armedDate { uptime.now = date }
        timer.fired()
        queue.fire()
    }

    /// The queue's wakes.
    var fires: UInt64 {
        ledger.snapshot().first { $0.owner == MainWakeUpQueue.ledgerOwner && $0.reason == "fire" }?.count ?? 0
    }
}

@MainActor
private final class AlignedLog {
    var ran: [Int] = []
}

/// Records each arm and park; the queue calls it with its lock held, the test reads it on the main actor.
private final class AlignedFakeTimer: MainWakeUpTimer, Sendable {
    struct Arm: Equatable, Sendable {
        var date: UInt64
        var tolerance: UInt64
    }

    private struct Record {
        var arms: [Arm] = []
        var parks = 0
        var armedDate: UInt64?
    }

    private let record = Mutex(Record())

    var arms: [Arm] { record.withLock { $0.arms } }
    var parks: Int { record.withLock { $0.parks } }
    var armedDate: UInt64? { record.withLock { $0.armedDate } }

    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {
        record.withLock { record in
            record.arms.append(Arm(date: date, tolerance: tolerance))
            record.armedDate = date
        }
    }

    func park() {
        record.withLock { record in
            record.parks += 1
            record.armedDate = nil
        }
    }

    /// What CFRunLoop does to the repeating timer when it fires: the next date is a park.
    func fired() {
        record.withLock { $0.armedDate = nil }
    }
}

/// The test's uptime, read by the queue under its lock.
private final class AlignedFakeUptime: Sendable {
    private let value: Atomic<UInt64>

    init(_ start: UInt64) {
        value = Atomic(start)
    }

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
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
