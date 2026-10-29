import CmuxNextCompat
import Dispatch
@testable import CmuxNextWakeups
import Testing

/// MainWakeUpQueue: one aligned timer for every main-thread deadline, Chromium's
/// WakeUpQueue plus `AdjustDelayedRunTime` in `CLOCK_UPTIME_RAW` ns. A fake timer records each arm,
/// a fake uptime stands in for the clock, and the test calls the timer's callout itself.
@MainActor
@Suite("MainWakeUpQueueTests")
struct MainWakeUpQueueTests {
    nonisolated private static let ms: UInt64 = 1_000_000

    @Test("Five flexible entries at 100-110 ms fire as two aligned wakes, in deadline order")
    func fiveEntriesTwoWakes() {
        let rig = WakeUpQueueRig()
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
        let saver = alignment == WakeLeeway.saverAlignment
        let rig = WakeUpQueueRig(energy: EnergyPolicySource(EnergyPolicy(saverReason: saver ? .setting : nil)))
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
        let rig = WakeUpQueueRig()
        let log = RunLog()
        rig.queue.insert(owner: "flex", at: 100 * Self.ms, window: .window(delay: .milliseconds(100))) { log.ran.append(100) }
        let precise = 10 * Self.ms + 123
        rig.queue.insert(owner: "precise", at: precise, window: .window(delay: .milliseconds(10), policy: .precise)) { log.ran.append(10) }
        #expect(rig.timer.arms.last == FakeWakeUpTimer.Arm(date: precise, tolerance: 0))
        rig.fire()
        #expect(log.ran == [10])
        #expect(rig.timer.armedDate == 104 * Self.ms)
    }

    @Test("Cancelling the earliest entry re-arms for the next; cancelling the last parks the timer")
    func cancelRearms() {
        let rig = WakeUpQueueRig()
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
        let rig = WakeUpQueueRig()
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
        let rig = WakeUpQueueRig()
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
        let rig = WakeUpQueueRig()
        for at: UInt64 in [100, 101, 102] {
            rig.queue.insert(owner: "same", at: at * Self.ms, window: .window(delay: .milliseconds(100))) {}
        }
        rig.fire()
        #expect(rig.queue.count == 0)
        #expect(rig.deadlines(of: "same") == 1)
        #expect(rig.fires == 1)
    }

    @Test("An entry whose action records its own wake gets no deadline record; the fire is still counted")
    func anEntryRecordedByItsActionGetsNoDeadlineRecord() {
        let rig = WakeUpQueueRig()
        let ledger = rig.ledger
        rig.queue.insert(owner: "pump", at: 100 * Self.ms, window: .window(delay: .milliseconds(100)),
                         ledgerReason: .recordedByAction) { ledger.record("pump", reason: "delayed") }
        rig.fire()
        #expect(rig.deadlines(of: "pump") == 0)
        #expect(ledger.snapshot().filter { $0.owner == "pump" }.map(\.reason) == ["delayed"])
        #expect(rig.fires == 1)
    }

    @Test("A deadlineWhenAlone entry records its deadline only in a wake that ran no other entry")
    func anEntryThatRodeAnotherWakeRecordsNoDeadline() {
        let rig = WakeUpQueueRig()
        rig.queue.insert(owner: "rider", at: 100 * Self.ms, window: .own(tolerance: .milliseconds(400), delay: .milliseconds(100)),
                         ledgerReason: .deadlineWhenAlone) {}
        rig.queue.insert(owner: "other", at: 200 * Self.ms, window: .window(delay: .milliseconds(200))) {}
        rig.fire()
        #expect(rig.queue.count == 0, "the rider ran in the other owner's wake")
        #expect(rig.deadlines(of: "rider") == 0)
        #expect(rig.deadlines(of: "other") == 1)

        rig.queue.insert(owner: "rider", at: 600 * Self.ms, window: .own(tolerance: .milliseconds(400), delay: .milliseconds(100)),
                         ledgerReason: .deadlineWhenAlone) {}
        rig.fire()
        #expect(rig.deadlines(of: "rider") == 1, "alone, its wake is its own")
        #expect(rig.fires == 2)
    }

    @Test("A fire that runs more than one entry counts as one coalesced fire; a fire of one entry does not")
    func coalescedFiresCountWakesThatRanSeveralEntries() {
        let rig = WakeUpQueueRig()
        for at: UInt64 in [100, 101, 102] {
            rig.queue.insert(owner: "a\(at)", at: at * Self.ms, window: .window(delay: .milliseconds(100))) {}
        }
        rig.fire()
        #expect(rig.queue.count == 0)
        #expect(rig.queue.coalescedFires == 1, "three entries shared one wake")
        rig.queue.insert(owner: "alone", at: 500 * Self.ms, window: .window(delay: .milliseconds(100))) {}
        rig.fire()
        #expect(rig.fires == 2)
        #expect(rig.queue.coalescedFires == 1, "a wake that runs one entry saved nothing")
        #expect(rig.ledger.snapshot().allSatisfy { $0.owner != MainWakeUpQueue.ledgerOwner || $0.reason == "fire" },
                "coalescing is not a wake, so it adds no ledger record")
    }

    @Test("A new top with a later fire date re-arms later, so the wake runs both entries")
    func newLaterTopRearms() {
        let rig = WakeUpQueueRig()
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
        let rig = WakeUpQueueRig()
        rig.uptime.now = 5_020 * Self.ms
        rig.queue.insert(owner: "soon", at: 4_950 * Self.ms, window: .window(delay: .seconds(1))) {}
        #expect(rig.timer.arms.last == FakeWakeUpTimer.Arm(date: 5_020 * Self.ms, tolerance: 30 * Self.ms),
                "aligned 5 s has passed: fire now, by the 5.05 s latest")
        rig.queue.insert(owner: "late", at: 2_000 * Self.ms, window: .window(delay: .seconds(1))) {}
        #expect(rig.timer.arms.last == FakeWakeUpTimer.Arm(date: 5_020 * Self.ms, tolerance: 0),
                "an overdue top re-arms the same date with no tolerance")
        #expect(rig.timer.arms.count == 2)
    }

    @Test("A fire after a cancel re-armed the timer later runs nothing early")
    func cancelRacingFireRunsNothingEarly() {
        let rig = WakeUpQueueRig()
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
        let rig = WakeUpQueueRig()
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
        let rig = WakeUpQueueRig()
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

    // MARK: Per-fire budget

    @Test("Fifty due entries of 0.1 ms run in three fires: each stops once its 2 ms budget has passed")
    func fireBudgetSplitsALongFire() {
        let rig = WakeUpQueueRig()
        let log = RunLog()
        Self.insertBusyEntries(into: rig, log: log, count: 50, cost: Self.ms / 10)
        var perFire: [Int] = []
        while rig.timer.armedDate != nil {
            let before = log.ran.count
            rig.fire()
            perFire.append(log.ran.count - before)
        }
        #expect(perFire == [20, 20, 10])
        #expect(log.ran == [UInt64](0..<50), "the entries left keep their order across fires")
        #expect(rig.queue.count == 0)
        #expect(rig.fires == 1, "the continuations are the same wake: one fire record")
        #expect(rig.deadlines(of: "busy") == 1, "one record per owner per wake")
        #expect(rig.queue.coalescedFires == 1, "a split wake counts once")
    }

    @Test("A fire that stops at its budget arms the rest for the current uptime with no tolerance")
    func aBudgetStopArmsTheRestForNowWithNoTolerance() {
        let rig = WakeUpQueueRig()
        let log = RunLog()
        Self.insertBusyEntries(into: rig, log: log, count: 50, cost: Self.ms / 10)
        rig.fire()
        #expect(rig.queue.count == 30)
        #expect(rig.timer.arms.last == FakeWakeUpTimer.Arm(date: rig.uptime.now, tolerance: 0),
                "the next run-loop pass, not a later grid tick or the top's latest time")
        rig.fire()
        #expect(log.ran == [UInt64](0..<40), "the rest runs on the next fire, in order")
    }

    @Test("An insert or a cancel during a continuation keeps its arm; emptying the queue ends the wake")
    func aContinuationKeepsItsArm() throws {
        let rig = WakeUpQueueRig()
        let log = RunLog()
        let tokens = Self.insertBusyEntries(into: rig, log: log, count: 2, cost: 5 * Self.ms)
        rig.fire()
        let continuation = try #require(rig.timer.arms.last)
        rig.queue.insert(owner: "later", after: .milliseconds(50)) {}
        rig.queue.insert(owner: "precise", at: rig.uptime.now + Self.ms, window: .window(delay: .milliseconds(1), policy: .precise)) {}
        #expect(rig.timer.arms.last == continuation && rig.timer.armedDate == continuation.date)
        for token in tokens { rig.queue.cancel(token) }
        #expect(rig.timer.armedDate == continuation.date, "entries are left: the continuation still fires")
        rig.fire()
        #expect(log.ran == [0] && rig.fires == 1)
        rig.fire()
        rig.fire()
        #expect(rig.queue.count == 0 && rig.fires == 3, "the fires after the continuation are wakes of their own")
    }

    @Test("The entry that crosses the budget finishes; the next one waits for the next fire")
    func longEntryRunsAlone() {
        let rig = WakeUpQueueRig()
        let log = RunLog()
        Self.insertBusyEntries(into: rig, log: log, count: 2, cost: 5 * Self.ms)
        rig.fire()
        #expect(log.ran == [0], "at least one entry per fire, however long")
        rig.fire()
        #expect(log.ran == [0, 1])
        #expect(rig.fires == 1 && rig.deadlines(of: "busy") == 1)
    }

    /// `count` entries due at 100 ms that each advance the fake uptime by `cost` ns and log their index.
    @discardableResult
    private static func insertBusyEntries(
        into rig: WakeUpQueueRig, log: RunLog, count: UInt64, cost: UInt64
    ) -> [MainWakeUpQueue.Token] {
        let uptime = rig.uptime
        return (0..<count).map { index in
            rig.queue.insert(owner: "busy", at: 100 * ms, window: .window(delay: .milliseconds(100))) {
                uptime.now += cost
                log.ran.append(index)
            }
        }
    }

    // MARK: Energy Saver

    @Test("Energy Saver snaps pending flexible entries to the 32 ms grid inside the latest they were inserted with")
    func saverRealignsFlexibleEntries() {
        let energy = EnergyPolicySource()
        let rig = WakeUpQueueRig(energy: energy)
        let log = RunLog()
        rig.queue.insert(owner: "flex", after: .milliseconds(100)) { log.ran.append(100) }
        rig.queue.insert(owner: "late", after: .milliseconds(450)) { log.ran.append(450) }
        rig.queue.insert(owner: "precise", after: .milliseconds(30), policy: .precise) { log.ran.append(30) }
        rig.queue.insert(owner: "seconds", after: .seconds(5)) { log.ran.append(5_000) }
        #expect(rig.timer.arms.map(\.date) == [104 * Self.ms, 30 * Self.ms], "8 ms grid, then the exact precise date")
        let armsBefore = rig.timer.arms.count

        energy.update(EnergyPolicy(saverReason: .lowPowerMode))

        #expect(rig.timer.arms.count == armsBefore, "the precise entry still fires first, at the same date: no re-arm")
        rig.fire()
        #expect(log.ran == [30])
        #expect(rig.timer.arms.last == FakeWakeUpTimer.Arm(date: 108 * Self.ms, tolerance: 0),
                "the 32 ms grid would say 128 ms; the entry keeps its 108 ms latest (AdjustDelayedRunTime)")
        rig.queue.insert(owner: "posted", after: .milliseconds(100)) { log.ran.append(130) }
        rig.fire()
        #expect(log.ran == [30, 100])
        #expect(rig.timer.arms.last == FakeWakeUpTimer.Arm(date: 160 * Self.ms, tolerance: 2 * Self.ms),
                "inserted under the saver at 30 ms: 32 ms leeway, 130 ms on the 32 ms grid")
        rig.fire()
        #expect(rig.timer.arms.last == FakeWakeUpTimer.Arm(date: 458 * Self.ms, tolerance: 0), "480 ms clamped to its 458 ms latest")
        rig.fire()
        #expect(rig.timer.arms.last == FakeWakeUpTimer.Arm(date: 5_000 * Self.ms, tolerance: 500 * Self.ms),
                "a whole-second entry keeps its grid and its 10% leeway")
        rig.fire()
        #expect(log.ran == [30, 100, 130, 450, 5_000])
    }

    @Test("Inserts under the saver take its 32 ms leeway; a switch back snaps them to the 8 ms grid at once")
    func switchBackAndCancel() {
        let energy = EnergyPolicySource(EnergyPolicy(saverReason: .setting))
        let rig = WakeUpQueueRig(energy: energy)
        let first = rig.queue.insert(owner: "a", after: .milliseconds(100)) {}
        rig.queue.insert(owner: "b", after: .milliseconds(200)) {}
        #expect(rig.timer.armedDate == 128 * Self.ms, "made under the saver: on the 32 ms grid")

        energy.update(.normal)

        #expect(rig.timer.armedDate == 104 * Self.ms, "back on the 8 ms grid: an earlier re-arm")
        #expect(rig.queue.cancel(first))
        #expect(rig.timer.armedDate == 200 * Self.ms)
    }

    @Test("An explicit sub-second window follows the grid too; whole-second ones and unchanged alignments do not")
    func explicitWindowFollowsTheGrid() {
        let energy = EnergyPolicySource()
        let rig = WakeUpQueueRig(energy: energy)
        rig.queue.insert(owner: "explicit", at: 100 * Self.ms, window: .window(delay: .milliseconds(100))) {}
        rig.queue.insert(owner: "seconds", at: 2_000 * Self.ms, window: .window(delay: .seconds(2))) {}
        energy.update(EnergyPolicy(onBattery: true))
        #expect(rig.timer.arms.map(\.date) == [104 * Self.ms], "the alignment did not change: no re-arm")

        energy.update(EnergyPolicy(saverReason: .battery, onBattery: true))

        #expect(rig.timer.arms.map(\.date) == [104 * Self.ms, 108 * Self.ms], "128 ms clamped to the 108 ms latest")
        rig.fire()
        #expect(rig.timer.arms.last == FakeWakeUpTimer.Arm(date: 2_000 * Self.ms, tolerance: 200 * Self.ms))
    }

    @Test("A hidden entry keeps its whole-second fence under the saver: it never snaps to the 32 ms grid")
    func hiddenEntryIgnoresTheSaverGrid() {
        let energy = EnergyPolicySource()
        let rig = WakeUpQueueRig(energy: energy, start: 10_000 * Self.ms + 1)
        let log = RunLog()
        rig.queue.insertHidden(owner: "hidden", after: .milliseconds(100)) { log.ran.append(1) }
        #expect(rig.timer.armedDate == 11_000 * Self.ms)

        energy.update(EnergyPolicy(saverReason: .setting))

        #expect(rig.timer.armedDate == 11_000 * Self.ms, "the saver moves only flexible sub-second entries")
        rig.fire()
        #expect(log.ran == [1])
    }

    @Test("A released queue stops observing the energy policy")
    func releasedQueueStopsObserving() {
        let energy = EnergyPolicySource()
        weak var released: MainWakeUpQueue?
        do {
            let rig = WakeUpQueueRig(energy: energy)
            released = rig.queue
            #expect(energy.observerCount == 1)
        }
        #expect(released == nil)
        #expect(energy.observerCount == 0)
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

@MainActor
private final class RunLog {
    var ran: [UInt64] = []
    var count = 0
}
