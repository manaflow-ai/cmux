@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// DemandTimer on the main thread's deadline queue: a main-actor action is a
/// MainWakeUpQueue entry, so it wakes no pool thread and never sleeps on the clock (Chromium's delayed
/// tasks share the pump's one `delayed_work_timer_`, base/message_loop/message_pump_apple.mm). The async
/// action starts one Task from the fire, the sync one (`scheduleOnMain`) runs inline in it, a reset or
/// cancel still wins, and a nonisolated action keeps the clock sleep. The queue runs on WakeUpQueueRig's
/// fake timer and uptime; the test fires it itself. A dropped entry is freed with no lock held, since its
/// action may own another timer. Queue deadlines are the queue's uptime, so these tests fire the queue;
/// the ManualClock only proves the sleep path is unused.
@MainActor
@Suite("DemandTimer main queue")
struct DemandTimerMainQueueTests {
    nonisolated private static let ms: UInt64 = 1_000_000
    nonisolated private static let owner = "test.demand-timer.main"

    /// One queue rig, a manual clock that counts sleeps, and a timer with both.
    @MainActor
    private struct Rig {
        let queue = WakeUpQueueRig()
        let clock = ManualClock()
        let timer: DemandTimer

        init(policy: DelayPolicy = .flexibleNoSooner) {
            timer = DemandTimer(owner: DemandTimerMainQueueTests.owner, policy: policy, clock: clock,
                                ledger: queue.ledger, wakeUps: queue.queue)
        }
    }

    @Test("A main-actor action at 100 ms runs from one queue fire and never sleeps on the clock")
    func mainActorActionRunsFromOneQueueFire() async {
        let rig = Rig()
        let fired = FiredSignal()
        rig.timer.schedule(after: .milliseconds(100)) { @MainActor in fired.fire() }
        #expect(rig.timer.isScheduled)
        #expect(rig.queue.queue.count == 1)
        #expect(rig.queue.timer.armedDate == 104 * Self.ms, "the 8 ms grid inside the 100 ms deadline's leeway")

        rig.queue.fire()
        await fired.wait()
        #expect(rig.clock.sleepRequests.isEmpty, "no pool thread slept for the deadline")
        #expect(rig.queue.fires == 1)
        #expect(rig.queue.deadlines(of: Self.owner) == 1)
        #expect(!rig.timer.isScheduled)
        #expect(rig.queue.timer.armedDate == nil, "the one-shot left nothing armed")
    }

    @Test("scheduleOnMain runs the action inline in the fire, with no Task")
    func syncActionRunsInline() {
        let rig = Rig()
        let log = RunLog()
        rig.timer.scheduleOnMain(after: .milliseconds(100)) { log.ran.append("sync") }
        rig.queue.fire()
        // No await between the fire and the check: only an inline run can have happened.
        #expect(log.ran == ["sync"])
        #expect(rig.clock.sleepRequests.isEmpty)
        #expect(rig.queue.fires == 1)
        #expect(rig.queue.deadlines(of: Self.owner) == 1)
        #expect(!rig.timer.isScheduled)
    }

    @Test("scheduleOnMainIfIdle keeps a pending deadline and schedules once it ran")
    func syncIfIdleKeepsThePendingDeadline() {
        let rig = Rig()
        let log = RunLog()
        rig.timer.scheduleOnMainIfIdle(after: .milliseconds(100)) { log.ran.append("first") }
        rig.timer.scheduleOnMainIfIdle(after: .milliseconds(300)) { log.ran.append("ignored") }
        #expect(rig.queue.queue.count == 1)
        #expect(rig.queue.timer.armedDate == 104 * Self.ms, "the first deadline is not pushed back")
        rig.queue.fire()
        #expect(log.ran == ["first"])

        rig.timer.scheduleOnMainIfIdle(after: .milliseconds(100)) { log.ran.append("second") }
        #expect(rig.timer.isScheduled, "an idle timer takes the next deadline")
        rig.queue.fire()
        #expect(log.ran == ["first", "second"])
        #expect(rig.clock.sleepRequests.isEmpty)
    }

    @Test("A reset drops the old entry: only the new deadline runs, at its own time")
    func resetWins() {
        let rig = Rig()
        let log = RunLog()
        rig.timer.scheduleOnMain(after: .milliseconds(100)) { log.ran.append("old") }
        rig.timer.scheduleOnMain(after: .milliseconds(300)) { log.ran.append("new") }
        #expect(rig.queue.queue.count == 1)
        #expect(rig.queue.timer.armedDate == 304 * Self.ms)
        rig.queue.fire()
        #expect(log.ran == ["new"])
        #expect(rig.queue.fires == 1)
    }

    @Test("A cancel drops the entry and parks the timer; nothing runs")
    func cancelWins() {
        let rig = Rig()
        let log = RunLog()
        rig.timer.scheduleOnMain(after: .milliseconds(100)) { log.ran.append("cancelled") }
        rig.timer.cancel()
        #expect(!rig.timer.isScheduled)
        #expect(rig.queue.queue.count == 0)
        #expect(rig.queue.timer.armedDate == nil)
        rig.queue.fire()
        #expect(log.ran.isEmpty)
    }

    @Test("A cancel by an earlier entry of the same fire wins over the timer's due entry")
    func cancelInTheSameFireWins() {
        let rig = Rig()
        let log = RunLog()
        let timer = rig.timer
        rig.queue.queue.insert(owner: "test.other", after: .milliseconds(100)) {
            log.ran.append("other")
            timer.cancel()
        }
        timer.scheduleOnMain(after: .milliseconds(100)) { log.ran.append("timer") }
        rig.queue.fire()
        #expect(log.ran == ["other"])
        #expect(rig.queue.deadlines(of: Self.owner) == 0)
        #expect(!timer.isScheduled)
    }

    @Test("An explicit zero tolerance fires exactly at the deadline, with no slack")
    func explicitZeroToleranceIsExact() {
        let rig = Rig()
        rig.timer.scheduleOnMain(after: .milliseconds(100), tolerance: .zero) {}
        #expect(rig.queue.timer.arms.last == FakeWakeUpTimer.Arm(date: 100 * Self.ms, tolerance: 0))
    }

    @Test("Releasing the timer drops its pending entry from the queue")
    func releaseDropsTheEntry() {
        let rig = WakeUpQueueRig()
        var timer: DemandTimer? = DemandTimer(owner: Self.owner, ledger: rig.ledger, wakeUps: rig.queue)
        timer?.scheduleOnMain(after: .milliseconds(100)) {}
        #expect(rig.queue.count == 1)
        timer = nil
        #expect(rig.queue.count == 0)
    }

    @Test("Releasing a timer frees its entry outside the queue's lock, even when the entry owns another queued timer")
    func releaseFreesAnEntryThatOwnsAnotherQueuedTimer() {
        let rig = WakeUpQueueRig()
        var first: DemandTimer? = DemandTimer(owner: Self.owner, ledger: rig.ledger, wakeUps: rig.queue)
        do {
            let box = TimerBox(DemandTimer(owner: "test.second", ledger: rig.ledger, wakeUps: rig.queue))
            box.timer.scheduleOnMain(after: .milliseconds(200)) {}
            first?.scheduleOnMain(after: .milliseconds(100)) { box.touch() }
        }
        #expect(rig.queue.count == 2)
        // The entry's action holds the last reference to the box, so freeing it deinits the second timer,
        // which cancels its own entry on the same queue (a re-entry of a held lock aborts the process).
        first = nil
        #expect(rig.queue.count == 0)
        #expect(rig.timer.armedDate == nil)
    }

    @Test("A reset frees the old entry outside the timer's lock, even when its action owns a canceller of that timer")
    func resetFreesAnEntryThatCancelsItsOwnTimer() {
        let rig = Rig()
        let log = RunLog()
        do {
            let canceller = CancelOnDeinit(rig.timer)
            rig.timer.scheduleOnMain(after: .milliseconds(100)) { canceller.touch() }
        }
        // The reset frees the old action, the canceller deinits and cancels the timer: the cancel is the
        // later call, so it wins over the new deadline.
        rig.timer.scheduleOnMain(after: .milliseconds(300)) { log.ran.append("new") }
        #expect(!rig.timer.isScheduled)
        #expect(rig.queue.queue.count == 0)
        rig.queue.fire()
        #expect(log.ran.isEmpty)
    }

    @Test("A nonisolated action sleeps on the clock and leaves the queue alone")
    func nonisolatedActionSleeps() async throws {
        let rig = Rig()
        let fired = FiredSignal()
        Self.scheduleNonisolated(on: rig.timer, fired: fired)
        try await rig.clock.waitForSleeper()
        #expect(rig.clock.sleepRequests.count == 1)
        #expect(rig.queue.queue.count == 0)
        #expect(rig.queue.timer.armedDate == nil)

        rig.clock.advance(by: .milliseconds(100))
        await fired.wait()
        #expect(rig.queue.fires == 0)
        #expect(rig.queue.deadlines(of: Self.owner) == 1)
        #expect(!rig.timer.isScheduled)
    }

    @Test("With no queue, scheduleOnMain sleeps on the clock and runs on the main actor")
    func noQueueSyncActionSleeps() async throws {
        let clock = ManualClock()
        let ledger = WakeupLedger(uptime: { 0 })
        let timer = DemandTimer(owner: Self.owner, clock: clock, ledger: ledger)
        let fired = FiredSignal()
        timer.scheduleOnMain(after: .milliseconds(100)) {
            MainActor.assertIsolated()
            fired.fire()
        }
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.count == 1)
        clock.advance(by: .milliseconds(100))
        await fired.wait()
        #expect(!timer.isScheduled)
    }

    /// Schedules from a nonisolated context, so the closure inherits no actor (`.isolation` is nil).
    nonisolated private static func scheduleNonisolated(on timer: DemandTimer, fired: FiredSignal) {
        timer.schedule(after: .milliseconds(100)) { await fired.fire() }
    }
}

/// Owns a timer; an entry's action that captures it holds the timer's last reference.
private final class TimerBox: Sendable {
    let timer: DemandTimer

    init(_ timer: DemandTimer) {
        self.timer = timer
    }

    func touch() {}
}

/// Cancels its timer when it deinits, as an owner that tears its deadline down does.
private final class CancelOnDeinit: Sendable {
    private let timer: DemandTimer

    init(_ timer: DemandTimer) {
        self.timer = timer
    }

    deinit {
        timer.cancel()
    }

    func touch() {}
}

@MainActor
private final class RunLog {
    var ran: [String] = []
}

/// A one-shot signal the async tests await instead of polling.
@MainActor
private final class FiredSignal {
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
