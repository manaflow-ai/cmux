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
        #expect(rig.timer.parks == 1, "the fire parks the arm it made for its own due entries")
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
            let entry = MainWakeUpHeap<Int>.Entry(id: UInt64(id), deadline: deadline, window: window, owner: "mix", payload: id)
            heap.insert(entry)
            latest = min(latest, entry.latest)
            let wakeUp = try #require(heap.wakeUp())
            #expect(wakeUp.date <= latest)
            #expect(wakeUp.latest == latest, "the slack runs to the smallest latest time")
        }
        let whole = MainWakeUpHeap<Int>.Entry(id: 9, deadline: 5_300 * Self.ms, window: .window(delay: .seconds(5)),
                                              owner: "s", payload: 9)
        var single = MainWakeUpHeap<Int>()
        single.insert(whole)
        let clamped = try #require(single.wakeUp())
        #expect(clamped.date == 5_800 * Self.ms, "6 s is past the 5.8 s latest: clamped to it")
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
        #expect(rig.timer.arms.map(\.date) == [104 * Self.ms, 104 * Self.ms, 304 * Self.ms],
                "the due insert arms for now (a nested run loop could fire it); the later one after it runs")
    }

    @Test("Entries of one owner that share a wake count as one ledger record")
    func oneRecordPerOwnerPerFire() {
        let rig = Rig()
        for at: UInt64 in [100, 101, 102] {
            rig.queue.insert(owner: "same", at: at * Self.ms, window: .window(delay: .milliseconds(100))) {}
        }
        rig.fire()
        #expect(rig.queue.count == 0)
        #expect(rig.deadlines(of: "same") == 1)
        #expect(rig.fires == 1)
    }

    @Test("A new top with a later fire date re-arms later, so the wake runs both entries")
    func newLaterTopRearms() {
        let rig = Rig()
        let log = RunLog()
        rig.queue.insert(owner: "flex", at: 100 * Self.ms, window: .window(delay: .milliseconds(100))) { log.ran.append(100) }
        rig.queue.insert(owner: "precise", at: 106 * Self.ms, window: .window(delay: .milliseconds(10), policy: .precise)) {
            log.ran.append(106)
        }
        #expect(rig.timer.arms.map(\.date) == [104 * Self.ms, 106 * Self.ms], "the precise top's latest is 106 < 108")
        rig.fire()
        #expect(log.ran == [106, 100])
        #expect(rig.fires == 1, "no wake at 104 that runs nothing")
    }

    @Test("A deadline that has passed arms for now with the tolerance left to its latest time")
    func pastDeadlineToleranceFromNow() {
        let rig = Rig()
        rig.uptime.now = 5_020 * Self.ms
        rig.queue.insert(owner: "soon", at: 4_950 * Self.ms, window: .window(delay: .seconds(1))) {}
        #expect(rig.timer.arms.last == FakeTimer.Arm(date: 5_020 * Self.ms, tolerance: 30 * Self.ms),
                "aligned 5 s has passed: fire now, by the 5.05 s latest")
        rig.queue.insert(owner: "late", at: 2_000 * Self.ms, window: .window(delay: .seconds(1))) {}
        #expect(rig.timer.arms.last == FakeTimer.Arm(date: 5_020 * Self.ms, tolerance: 0),
                "an overdue top re-arms the same date with no tolerance")
        #expect(rig.timer.arms.count == 2)
    }

    @Test("A fire after a cancel re-armed the timer later runs nothing early")
    func cancelRacingFireRunsNothingEarly() {
        let rig = Rig()
        let log = RunLog()
        let first = rig.queue.insert(owner: "a", at: 100 * Self.ms, window: .window(delay: .milliseconds(100))) {
            log.ran.append(100)
        }
        rig.queue.insert(owner: "b", at: 196 * Self.ms, window: .window(delay: .milliseconds(100))) { log.ran.append(196) }
        #expect(rig.timer.armedDate == 104 * Self.ms)
        rig.uptime.now = 104 * Self.ms
        rig.timer.fired()
        rig.queue.cancel(first)
        #expect(rig.timer.armedDate == 200 * Self.ms, "a background cancel re-arms while the fire is on its way")
        rig.queue.fire()
        #expect(log.ran.isEmpty, "b may not run before 196 ms")
        #expect(rig.timer.armedDate == 200 * Self.ms && rig.queue.count == 1)
    }

    @Test("An entry that spins a nested run loop does not stop later deadlines")
    func nestedRunLoopStillFires() {
        let rig = Rig()
        let log = RunLog()
        let queue = rig.queue
        queue.insert(owner: "menu", at: 100 * Self.ms, window: .window(delay: .milliseconds(100))) {
            log.ran.append(1)
            let hide = WakeLeeway.window(delay: .milliseconds(10), policy: .precise)
            queue.insert(owner: "hide", at: rig.uptime.now + 10 * Self.ms, window: hide) { log.ran.append(2) }
            #expect(rig.timer.armedDate == 114 * Self.ms, "armed while the entry still runs")
            rig.fire()
            log.ran.append(3)
        }
        rig.fire()
        #expect(log.ran == [1, 2, 3])
        #expect(rig.fires == 2 && queue.count == 0)
    }

    @Test("4 threads x 1000 concurrent inserts lose nothing and never move the fire date later")
    func concurrentInserts() {
        let rig = Rig()
        let log = RunLog()
        Self.insertConcurrently(into: rig.queue, log: log)
        #expect(rig.queue.count == 4_000)
        let dates = rig.timer.arms.map(\.date)
        #expect(zip(dates, dates.dropFirst()).allSatisfy { $0 >= $1 }, "a same-date re-arm only shortens the tolerance")
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
