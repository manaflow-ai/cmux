import CmuxNextCompat
import Dispatch
@testable import CmuxNextWakeups
import Testing

/// MainWakeUpQueue (p14-energy-013): one aligned timer for every main-thread deadline, Chromium's
/// WakeUpQueue plus `AdjustDelayedRunTime` in `CLOCK_UPTIME_RAW` ns. A fake timer records each arm,
/// a fake uptime stands in for the clock, and the test calls the timer's callout itself.
@MainActor
@Suite("MainWakeUpQueueTests")
struct MainWakeUpQueueTests {
    nonisolated private static let ms: UInt64 = 1_000_000

    @Test("Five flexible entries at 100-110 ms fire as two aligned wakes, in deadline order")
    func fiveEntriesTwoWakes() {
        let rig = Rig()
        let log = RunLog()
        for at: UInt64 in [110, 100, 107, 103, 105] {
            rig.queue.insert(owner: "e\(at)", at: at * Self.ms, window: .window(delay: .milliseconds(100))) { log.ran.append(at) }
        }
        #expect(rig.timer.armedDate == 104 * Self.ms, "100 ms snapped up to the 8 ms grid")
        rig.fire()
        #expect(log.ran == [100, 103])
        #expect(rig.timer.armedDate == 112 * Self.ms, "105 ms snapped to 112, inside its 113 ms latest")
        rig.fire()
        #expect(log.ran == [100, 103, 105, 107, 110])
        #expect(rig.fires == 2)
        #expect(rig.queue.count == 0)
        #expect(rig.timer.parks == 0, "the last fire leaves the timer parked by CFRunLoop: no extra call")
        #expect(rig.deadlines(of: "e107") == 1)
    }

    @Test("Aligned fire dates are exact multiples of the grid in uptime ns", arguments: [WakeLeeway.defaultAlignment, WakeLeeway.saverAlignment])
    func gridMultiples(alignment: Duration) throws {
        let rig = Rig(alignment: alignment)
        let grid = alignment.nanosecondCount
        var deadline: UInt64 = 900 * Self.ms + 123_457
        for step in 0..<40 {
            deadline -= UInt64(step % 7 + 1) * 3 * Self.ms + 17
            rig.queue.insert(owner: "grid", at: deadline, window: .window(delay: .milliseconds(200), alignment: alignment)) {}
            let date = try #require(rig.timer.armedDate)
            #expect(date % grid == 0, "\(date) on the \(grid) ns grid")
            #expect(date >= deadline && date < deadline + grid, "the first tick at or after the deadline")
        }
    }

    @Test("A fire date is never after the latest time of any pending entry")
    func neverAfterLatest() throws {
        var heap = MainWakeUpHeap<Int>()
        let windows: [(UInt64, WakeLeeway)] = [
            (5_000 * Self.ms + 300 * Self.ms, .window(delay: .seconds(5))),
            (1_200 * Self.ms + 1, .window(delay: .seconds(1), policy: .flexiblePreferEarly)),
            (450 * Self.ms + 5, .window(delay: .milliseconds(450))),
            (447 * Self.ms + 7, .window(delay: .milliseconds(450), policy: .flexiblePreferEarly)),
            (60_000 * Self.ms + 999, .window(delay: .seconds(60))),
            (441 * Self.ms + 3, .window(delay: .milliseconds(20), policy: .precise)),
        ]
        var latest = UInt64.max
        for (id, (deadline, window)) in windows.enumerated() {
            let entry = MainWakeUpHeap<Int>.Entry(
                id: UInt64(id), earliest: window.earliest(deadline: deadline), latest: window.latest(deadline: deadline),
                grid: window.policy == .precise ? 0 : window.grid.nanosecondCount, owner: "mix", payload: id)
            heap.insert(entry)
            latest = min(latest, entry.latest)
            let wakeUp = try #require(heap.wakeUp())
            #expect(wakeUp.date <= latest)
            #expect(wakeUp.date + wakeUp.tolerance == latest, "the tolerance runs to the latest time")
        }
        let whole = MainWakeUpHeap<Int>.Entry(id: 9, earliest: 5_300 * Self.ms, latest: 5_800 * Self.ms,
                                              grid: 1_000 * Self.ms, owner: "s", payload: 9)
        var single = MainWakeUpHeap<Int>()
        single.insert(whole)
        let clamped = try #require(single.wakeUp())
        #expect(clamped.date == 5_800 * Self.ms, "6 s is past the latest: clamped to 5.8 s")
    }

    @Test("A precise entry fires at its own deadline with no tolerance")
    func preciseIsNotAligned() {
        let rig = Rig()
        let log = RunLog()
        rig.queue.insert(owner: "flex", at: 100 * Self.ms, window: .window(delay: .milliseconds(100))) { log.ran.append(100) }
        let precise = 10 * Self.ms + 123
        rig.queue.insert(owner: "precise", at: precise, window: .window(delay: .milliseconds(10), policy: .precise)) { log.ran.append(10) }
        #expect(rig.timer.arms.last == FakeTimer.Arm(date: precise, tolerance: 0))
        rig.fire()
        #expect(log.ran == [10])
        #expect(rig.timer.armedDate == 104 * Self.ms)
    }

    @Test("Cancelling the earliest entry re-arms for the next; cancelling the last parks the timer")
    func cancelRearms() {
        let rig = Rig()
        let first = rig.queue.insert(owner: "a", at: 100 * Self.ms, window: .window(delay: .milliseconds(100))) {}
        let second = rig.queue.insert(owner: "b", at: 200 * Self.ms, window: .window(delay: .milliseconds(100))) {}
        #expect(rig.timer.armedDate == 104 * Self.ms)
        #expect(rig.queue.cancel(first))
        #expect(rig.timer.armedDate == 200 * Self.ms)
        #expect(!rig.queue.cancel(first), "a second cancel finds nothing")
        #expect(rig.queue.cancel(second))
        #expect(rig.timer.parks == 1 && rig.queue.count == 0)
    }

    @Test("An insert that does not move the fire date earlier makes no re-arm call")
    func sameEarliestNoRearm() {
        let rig = Rig()
        rig.queue.insert(owner: "a", at: 100 * Self.ms, window: .window(delay: .milliseconds(100))) {}
        rig.queue.insert(owner: "b", at: 100 * Self.ms, window: .window(delay: .milliseconds(100))) {}
        rig.queue.insert(owner: "c", at: 101 * Self.ms, window: .window(delay: .milliseconds(100))) {}
        rig.queue.insert(owner: "d", at: 150 * Self.ms, window: .window(delay: .milliseconds(100))) {}
        let other = rig.queue.insert(owner: "e", at: 300 * Self.ms, window: .window(delay: .milliseconds(100))) {}
        rig.queue.cancel(other)
        #expect(rig.timer.arms.count == 1)
        rig.queue.insert(owner: "f", at: 90 * Self.ms, window: .window(delay: .milliseconds(100))) {}
        #expect(rig.timer.arms.map(\.date) == [104 * Self.ms, 96 * Self.ms], "earlier: one re-arm")
    }

    @Test("An entry inserted during a fire that is already due runs in the same pass")
    func dueInsertDuringFire() {
        let rig = Rig()
        let log = RunLog()
        let queue = rig.queue
        queue.insert(owner: "outer", at: 100 * Self.ms, window: .window(delay: .milliseconds(100))) {
            log.ran.append(1)
            queue.insert(owner: "due", at: 99 * Self.ms, window: .window(delay: .zero)) { log.ran.append(2) }
            queue.insert(owner: "later", at: 300 * Self.ms, window: .window(delay: .milliseconds(100))) { log.ran.append(3) }
        }
        rig.fire()
        #expect(log.ran == [1, 2])
        #expect(rig.fires == 1)
        #expect(rig.timer.arms.map(\.date) == [104 * Self.ms, 304 * Self.ms], "no arm while firing; one at its end")
    }

    @Test("A fire stops after its 2 ms slice and arms for the rest at once")
    func sliceBudgetYields() {
        let rig = Rig()
        let log = RunLog()
        let uptime = rig.uptime
        rig.queue.insert(owner: "slow", at: 100 * Self.ms, window: .window(delay: .milliseconds(100))) {
            log.ran.append(100)
            uptime.now += 3 * Self.ms
        }
        for at: UInt64 in [101, 102] {
            rig.queue.insert(owner: "next", at: at * Self.ms, window: .window(delay: .milliseconds(100))) { log.ran.append(at) }
        }
        rig.fire()
        #expect(log.ran == [100], "the slow entry used the whole slice")
        #expect(rig.timer.armedDate == 104 * Self.ms, "armed for a date that has passed: it fires at once")
        #expect(uptime.now == 107 * Self.ms)
        rig.timer.fired()
        rig.queue.fire()
        #expect(log.ran == [100, 101, 102])
        #expect(rig.fires == 2 && rig.queue.count == 0)
    }

    @Test("A fire a little before the armed date still runs what that date is for")
    func earlyFireRunsArmedEntries() {
        let rig = Rig()
        let log = RunLog()
        rig.queue.insert(owner: "a", at: 104 * Self.ms, window: .window(delay: .milliseconds(100))) { log.ran.append(104) }
        #expect(rig.timer.armedDate == 104 * Self.ms)
        rig.uptime.now = 104 * Self.ms - 3_000
        rig.timer.fired()
        rig.queue.fire()
        #expect(log.ran == [104])
        #expect(rig.fires == 1)
    }

    @Test("4 threads x 1000 concurrent inserts lose nothing and only ever move the fire date earlier")
    func concurrentInserts() {
        let rig = Rig()
        let log = RunLog()
        Self.insertConcurrently(into: rig.queue, log: log)
        #expect(rig.queue.count == 4_000)
        let dates = rig.timer.arms.map(\.date)
        #expect(zip(dates, dates.dropFirst()).allSatisfy { $0 > $1 })
        #expect(dates.last == 8 * Self.ms, "the 1 ms entry, on the grid")
        rig.uptime.now = 2_000 * Self.ms
        rig.timer.fired()
        rig.queue.fire()
        #expect(log.count == 4_000)
        #expect(rig.fires == 1 && rig.queue.count == 0)
    }

    nonisolated private static func insertConcurrently(into queue: MainWakeUpQueue, log: RunLog) {
        DispatchQueue.concurrentPerform(iterations: 4) { thread in
            for index in 0..<1_000 {
                let at = UInt64((index * 7_919 + thread * 13) % 1_000 + 1) * ms
                queue.insert(owner: "t\(thread)", at: at, window: .window(delay: .milliseconds(100))) { log.count += 1 }
            }
        }
    }
}

/// The queue under test with a fake timer, a fake uptime and its own ledger.
@MainActor
private struct Rig {
    let timer = FakeTimer()
    let uptime = FakeUptime()
    let ledger = WakeupLedger(uptime: { 0 })
    let queue: MainWakeUpQueue

    init(alignment: Duration = WakeLeeway.defaultAlignment) {
        let timer = timer, uptime = uptime
        queue = MainWakeUpQueue(alignment: alignment, ledger: ledger, uptime: { uptime.now }) { _ in timer }
    }

    /// Moves the uptime to the armed date and runs the timer's callout.
    func fire() {
        if let date = timer.armedDate { uptime.now = date }
        timer.fired()
        queue.fire()
    }

    var fires: UInt64 { count(MainWakeUpQueue.ledgerOwner, reason: "fire") }
    func deadlines(of owner: String) -> UInt64 { count(owner, reason: "deadline") }

    private func count(_ owner: String, reason: String) -> UInt64 {
        ledger.snapshot().first { $0.owner == owner && $0.reason == reason }?.count ?? 0
    }
}

@MainActor
private final class RunLog {
    var ran: [UInt64] = []
    var count = 0
}

/// Records each arm and park. The queue calls it from the inserting threads and the test reads it on the
/// main actor, so the record is behind its own lock.
private final class FakeTimer: MainWakeUpTimer, Sendable {
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

    /// What CFRunLoop does to the parked repeating timer when it fires: the next date is a park.
    func fired() {
        record.withLock { $0.armedDate = nil }
    }
}

/// The test's uptime, read by the queue from any thread.
private final class FakeUptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}
