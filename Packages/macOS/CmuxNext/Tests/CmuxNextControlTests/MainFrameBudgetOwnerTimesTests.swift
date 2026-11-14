import CmuxNextWakeups
import Foundation
import Testing

/// The always-on per-owner task record of the main-thread scheduler (plans/cmux-next/main-thread-scheduling.md 1.2,
/// gap G3): every task ``MainFrameBudget/run(_:owner:_:)`` runs, of any class, adds its own time to its owner's
/// fixed-size histogram, so `debug.main_budget` names the owner of a long task with no diagnostics mode.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainFrameBudgetOwnerTimesTests {
    @Test func eachTaskTimeLandsInItsOwnersHistogram() throws {
        let clock = OwnerTimesClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let drain = budget.board.owner("daemon.store.drain")
        let rows = budget.board.owner("SidebarRows")
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 120)
        // Frame-class work (the store drain) is unbudgeted, but it is recorded like every other task.
        for ms in [0.5, 0.5, 0.5, 0.5, 9.0] {
            budget.run(.frame, owner: drain) { clock.advance(ms: ms) }
        }
        budget.run(.visible, owner: rows) { clock.advance(ms: 1) }

        let times = Dictionary(uniqueKeysWithValues: budget.ownerTimes.map { ($0.owner, $0) })
        let drainTimes = try #require(times["daemon.store.drain"], "the drain's tasks are in its owner's record")
        #expect(drainTimes.count == 5)
        #expect(drainTimes.maxNanos == 9_000_000, "the longest task is exact")
        #expect(drainTimes.totalNanos == 11_000_000)
        #expect(drainTimes.over8msCount == 1, "a task over 8 ms is counted as the failure line")
        // p50 and p95 come from log buckets (4 per octave): within a quarter above the true value, never past the max.
        #expect((500_000...625_000).contains(drainTimes.p50Nanos), "p50 \(drainTimes.p50Nanos)")
        #expect((9_000_000...9_000_000).contains(drainTimes.p95Nanos), "p95 \(drainTimes.p95Nanos): the bucket's edge, clamped to the max")
        let rowTimes = try #require(times["SidebarRows"])
        #expect(rowTimes.count == 1)
        #expect(rowTimes.maxNanos == 1_000_000)
        #expect(budget.ownerTimes.first?.owner == "daemon.store.drain", "owners are listed by total time, largest first")
    }

    @Test func aNestedTaskIsChargedToItsOwnOwnerOnly() throws {
        let clock = OwnerTimesClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let batch = budget.board.owner("Control.frames")
        let request = budget.board.owner("workspace.move")
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 120)
        budget.run(.automation, owner: batch) {
            clock.advance(ms: 1)
            budget.run(.automation, owner: request) { clock.advance(ms: 3) }
        }
        let times = Dictionary(uniqueKeysWithValues: budget.ownerTimes.map { ($0.owner, $0) })
        #expect(try #require(times["Control.frames"]).maxNanos == 1_000_000, "the outer task's own time, without its child's")
        #expect(try #require(times["workspace.move"]).maxNanos == 3_000_000)
    }

    /// G4: the daemon store drain is a frame queue on the app's scheduler; each batch is a recorded frame task of
    /// `daemon.store.drain`, published on the board while it runs and timed in the owner record, and it still runs whole
    /// every frame (never held by the budget).
    @Test func theStoreDrainsBatchesAreRecordedUnderItsOwner() throws {
        let clock = OwnerTimesClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in OwnerTimesFrameLink() }
        let drain = FrameBatchQueue(owner: "daemon.store.drain", frameOn: scheduler)
        var running: [String?] = []
        for frame in 1...3 {
            // A batch longer than the whole scheduled budget: a frame task is never held for the next frame.
            drain.enqueue {
                running.append(budget.board.running?.owner)
                clock.advance(ms: 6)
            }
            clock.advance(ms: 9)
            scheduler.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 120)
        }
        #expect(running == ["daemon.store.drain", "daemon.store.drain", "daemon.store.drain"], "the watchdog names the drain")
        #expect(drain.count == 0)
        let times = try #require(budget.ownerTimes.first { $0.owner == "daemon.store.drain" })
        #expect(times.count == 3)
        #expect(times.maxNanos == 6_000_000)
        #expect(budget.board.running == nil)
    }

    @Test func resetClearsTheOwnerTimes() {
        let clock = OwnerTimesClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let owner = budget.board.owner("SidebarRows")
        budget.run(.visible, owner: owner) { clock.advance(ms: 2) }
        #expect(budget.ownerTimes.count == 1)
        budget.resetStats()
        #expect(budget.ownerTimes.isEmpty, "debug.main_budget reset starts a fresh record")
        budget.run(.visible, owner: owner) { clock.advance(ms: 1) }
        #expect(budget.ownerTimes.first?.maxNanos == 1_000_000)
    }

    /// More owners RUN tasks than the record has slots: the ones that run after the last slot is taken share one row.
    @Test func ownersPastTheRecordsCapacityShareOneSlot() throws {
        let clock = OwnerTimesClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let owners = (0..<(MainFrameBudget.ownerTimesCapacity + 10)).map { budget.board.owner("owner \($0)") }
        for owner in owners {
            budget.run(.automation, owner: owner) { clock.advance(ms: 0.1) }
        }
        let times = budget.ownerTimes
        let overflow = try #require(times.first { $0.owner == MainFrameBudget.overflowOwnerName })
        // Slot 0 is the shared one, so the first capacity - 1 owners that run have their own slot and the rest share one.
        #expect(overflow.count == owners.count - (MainFrameBudget.ownerTimesCapacity - 1))
        #expect(times.reduce(0) { $0 + $1.count } == owners.count, "no task is lost")
    }

    /// The app binds its actions first, and each bound action takes one board number (`MainTaskBoard.internOwner`,
    /// from `ActionBudgetMonitor.intern`): more of them than the record has slots. An action publishes a span on the
    /// board; it records no task here. So an owner that runs its first task after them (an observation site, a queue)
    /// must still have its own row with its own name: `debug.main_budget` exists to name it.
    @Test func anOwnerThatRunsAfterManyInternedNamesKeepsItsOwnRow() throws {
        let clock = OwnerTimesClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let bound = max(600, MainFrameBudget.ownerTimesCapacity + 88)
        for action in 0..<bound { _ = budget.board.internOwner("action.\(action)") }
        let site = budget.board.owner("CmuxNextBridge/OpenTabFavicons.swift:45")
        let queue = budget.board.owner("a queue built late")
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 120)
        budget.runArrived(.visible, owner: site) { clock.advance(ms: 9) }
        budget.run(.automation, owner: queue) { clock.advance(ms: 2) }

        let times = Dictionary(uniqueKeysWithValues: budget.ownerTimes.map { ($0.owner, $0) })
        let siteTimes = try #require(times["CmuxNextBridge/OpenTabFavicons.swift:45"],
                                     "the observation site has its own row, rows: \(times.keys.sorted())")
        #expect(siteTimes.count == 1)
        #expect(siteTimes.maxNanos == 9_000_000, "the longest task is exact")
        #expect(siteTimes.over8msCount == 1, "the task over 8 ms has a name")
        let queueTimes = try #require(times["a queue built late"], "the late owner has its own row, rows: \(times.keys.sorted())")
        #expect(queueTimes.count == 1)
        #expect(queueTimes.maxNanos == 2_000_000)
        #expect(times[MainFrameBudget.overflowOwnerName] == nil, "two owners ran: nothing is in the shared row")
    }

    /// `debug.main_budget reset` starts a fresh record: the owners that ran before it give their slots back, so the
    /// owners of the next measurement have their own rows also after a full record.
    @Test func resetGivesTheSlotsBackToTheOwnersThatRunNext() throws {
        let clock = OwnerTimesClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        // More owners than the record has slots run one task each: the record is full.
        for index in 0..<(MainFrameBudget.ownerTimesCapacity + 10) {
            budget.run(.automation, owner: budget.board.owner("before \(index)")) { clock.advance(ms: 0.1) }
        }
        #expect(budget.ownerTimes.contains { $0.owner == MainFrameBudget.overflowOwnerName }, "fixture: the record is full")
        budget.resetStats()
        #expect(budget.ownerTimes.isEmpty)
        budget.run(.visible, owner: budget.board.owner("after the reset")) { clock.advance(ms: 3) }
        budget.run(.automation, owner: budget.board.owner("before 0")) { clock.advance(ms: 1) }
        let times = Dictionary(uniqueKeysWithValues: budget.ownerTimes.map { ($0.owner, $0) })
        #expect(times.keys.sorted() == ["after the reset", "before 0"])
        #expect(times["after the reset"]?.maxNanos == 3_000_000)
        #expect(times["before 0"]?.maxNanos == 1_000_000, "an owner that ran before the reset starts at zero")
    }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class OwnerTimesClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64((ms * 1_000_000).rounded()) }
}

@MainActor
private final class OwnerTimesFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
