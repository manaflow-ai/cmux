@testable import CmuxNextControl
import CmuxNextCompat
@testable import CmuxNextWakeups
import Testing

/// p14-energy-065: the busy watchdog's window ends on the main thread's deadline queue, never sooner than the
/// window and at most its 10 s leeway after it, so the end rides another main wake when there is one (Chromium's
/// `subtle::DelayPolicy::kFlexibleNoSooner`, base/task/delay_policy.h). Only a wake before the window's nominal end
/// keeps the watch going, so alone the end fires once, at most 20 s after the wake that opened the window. Shares
/// are judged over the real elapsed time. The queue runs on a fake timer and uptime the test drives; the close
/// runs inline.
@MainActor
@Suite("BusyWatchdog wake queue")
struct BusyWatchdogWakeQueueTests {
    nonisolated private static let second: UInt64 = 1_000_000_000

    /// A queue on a fake timer and uptime, and a watchdog on that queue and uptime with its own ledger and log.
    @MainActor
    private struct Rig {
        let timer = BusyWindowTimer()
        let uptime = BusyWindowUptime()
        let ledger = WakeupLedger(uptime: { 0 })
        let log = HangLog()
        let queue: MainWakeUpQueue
        let watchdog: BusyWatchdog

        /// - Parameter threshold: The main-thread and process thresholds; below zero every window is busy.
        init(threshold: Double = 100) {
            let timer = timer, uptime = uptime
            queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: ledger, uptime: { uptime.now }) { _ in timer }
            let configuration = BusyWatchdog.Configuration(mainThreadThreshold: threshold, processThreshold: threshold,
                                                           helperThreshold: 100, logBusy: false)
            watchdog = BusyWatchdog(configuration: configuration, log: log, ledger: ledger, activity: ExpectedActivity(),
                                    clock: ContinuousClock(), wakeUps: queue, uptime: { uptime.now }, offMain: { $0() })
        }

        /// The main run loop wakes at `nanos` for something else.
        func wake(at nanos: UInt64) {
            uptime.now = nanos
            watchdog.noteAwake()
        }

        /// The queue's timer fires at `nanos`: the run loop wakes (its observer notes the wake), then the fire runs.
        func fire(at nanos: UInt64) {
            wake(at: nanos)
            timer.fired()
            queue.fire()
        }

        /// The window ends the ledger counted.
        var windowEnds: UInt64 {
            ledger.snapshot().first { $0.owner == BusyWatchdog.windowOwner && $0.reason == "deadline" }?.count ?? 0
        }
    }

    @Test("The window end is never sooner than the window and at most 10 s after it")
    func windowEndIsFlexibleNoSoonerWithTenSecondsOfLeeway() throws {
        let rig = Rig()
        rig.wake(at: 0)
        #expect(rig.queue.count == 1, "the end is a queue entry, not a sleep")
        let arm = try #require(rig.timer.arms.last)
        #expect(arm.date == 10 * Self.second)
        #expect(arm.date + arm.tolerance == 20 * Self.second)
    }

    @Test("Alone, the window ends once and the watch stops: the fire's own wake does not keep it going")
    func withNoOtherWakeTheWatchStopsAfterOneWindow() {
        let rig = Rig()
        rig.wake(at: 1 * Self.second)
        rig.fire(at: 21 * Self.second)
        #expect(rig.windowEnds == 1)
        #expect(rig.queue.count == 0, "no further window")
        #expect(rig.timer.armedDate == nil)

        rig.wake(at: 40 * Self.second)
        #expect(rig.queue.count == 1, "the next wake opens a window again")
    }

    @Test("A wake before the nominal end opens the next window at once")
    func aWakeBeforeTheNominalEndKeepsWatching() {
        let rig = Rig()
        rig.wake(at: 0)
        rig.wake(at: 5 * Self.second)
        rig.fire(at: 10 * Self.second)
        #expect(rig.windowEnds == 1)
        #expect(rig.queue.count == 1, "the next window opened")
        #expect(rig.timer.armedDate == 20 * Self.second)

        rig.fire(at: 30 * Self.second)
        #expect(rig.windowEnds == 2)
        #expect(rig.queue.count == 0, "that window saw no wake before its end")
    }

    @Test("The end rides another main deadline inside its leeway: one wake for both")
    func windowEndRidesAnotherDeadline() {
        let rig = Rig()
        let other = RanFlag()
        rig.wake(at: 0)
        rig.queue.insert(owner: "test.other", after: .seconds(12)) { other.ran = true }
        #expect(rig.timer.armedDate == 12 * Self.second, "no wake of its own at 10 s")
        rig.fire(at: 12 * Self.second)
        #expect(other.ran)
        #expect(rig.windowEnds == 1)
        #expect(rig.queue.coalescedFires == 1)
        #expect(rig.queue.count == 0)
    }

    @Test("A busy window's record spans the real elapsed time, not the configured window")
    func sharesUseTheElapsedTime() throws {
        let rig = Rig(threshold: -1)
        rig.wake(at: 2 * Self.second)
        rig.fire(at: 17 * Self.second)
        let record = try #require(rig.log.records().first { $0.kind == .busy })
        #expect(record.duration == .seconds(15))
        #expect(record.startUptimeNanos == 2 * Self.second)
    }
}

/// A queue entry's work ran (read on the main actor, where the queue runs it).
@MainActor
private final class RanFlag {
    var ran = false
}

/// Records each arm of the queue's timer; the queue arms from any thread.
private final class BusyWindowTimer: MainWakeUpTimer, Sendable {
    struct Arm: Sendable {
        var date: UInt64
        var tolerance: UInt64
    }

    private struct Record {
        var arms: [Arm] = []
        var armedDate: UInt64?
    }

    private let state = Mutex(Record())

    var arms: [Arm] { state.withLock { $0.arms } }
    var armedDate: UInt64? { state.withLock { $0.armedDate } }

    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {
        state.withLock { state in
            state.arms.append(Arm(date: date, tolerance: tolerance))
            state.armedDate = date
        }
    }

    func park() {
        state.withLock { $0.armedDate = nil }
    }

    /// What CFRunLoop does to the repeating timer when it fires: it stays parked unless the fire arms it again.
    func fired() {
        state.withLock { $0.armedDate = nil }
    }
}

/// The test's uptime, shared by the queue and the watchdog.
private final class BusyWindowUptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}
