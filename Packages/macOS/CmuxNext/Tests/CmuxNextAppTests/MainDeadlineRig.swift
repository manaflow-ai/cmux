import CmuxNextCompat
@testable import CmuxNextWakeups
import Foundation

/// The app's deadline scheduler on a wake-up queue the test fires, at a fake uptime, with posted work run by hand-fired
/// frames: CmuxNextWakeupsTests' DeadlineHarness for App tests of a ``MainDeadline`` owner. Nothing fires on its own.
@MainActor
final class MainDeadlineRig {
    let deadlines: MainDeadlineScheduler
    private let timer: HandFiredWakeUpTimer
    private let uptime: RigUptime
    private let queue: MainWakeUpQueue
    /// The rig's scheduler: its posted work runs at ``frame()``.
    let work: MainWorkScheduler
    private let budgetClock: RigUptime
    private let keeper: FrameClient
    private var frames: Double = 0

    /// - Parameter startup: The scheduler's launch phases; a test of work the launch holds passes a launching one.
    /// - Parameter framed: Whether frames run (a kept frame client): posted work then runs at ``frame()``. False runs
    ///   it on the next main run loop turn, as an idle app does, for a test whose replies come back off main.
    init(startup: StartupPhase = .settled(), framed: Bool = true) {
        let timer = HandFiredWakeUpTimer(), uptime = RigUptime(0), budgetClock = RigUptime(1_000_000_000)
        self.timer = timer
        self.uptime = uptime
        self.budgetClock = budgetClock
        let queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }), uptime: { uptime.now }) { _ in timer }
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: { budgetClock.now }), ledger: WakeupLedger(),
                                             startup: startup) { _ in RigLink() }
        self.queue = queue
        self.work = work
        deadlines = MainDeadlineScheduler(work: work, queue: queue)
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        self.keeper = keeper
        if framed { keeper.activate() }
    }

    /// Seconds of uptime since the rig began.
    var elapsed: TimeInterval { Double(uptime.now) / 1_000_000_000 }

    /// Moves the uptime on without firing anything.
    func advance(by duration: Duration) { uptime.now += duration.nanosecondCount }

    /// Moves the uptime to the armed wake, fires the queue and runs the posted actions in one frame.
    func fireAndRun() {
        if let date = timer.armedDate { uptime.now = max(uptime.now, date) }
        timer.armedDate = nil
        queue.fire()
        frame()
    }

    /// Fires the queue at the current uptime, as a wake that came before the armed date, and runs the posted actions
    /// in one frame: only what is due by now runs, and the wake stays armed for the rest.
    func fireAtNow() {
        queue.fire()
        frame()
    }

    /// One display frame with no wake: runs the posted work only (an observation's flush), uptime unmoved.
    func frame() {
        budgetClock.now += 17_000_000
        frames += 1
        work.frameDidFire(timestamp: frames, refreshInterval: 1.0 / 60)
    }

    /// Whether a wake is armed (a pending deadline).
    var hasArmedWake: Bool { timer.armedDate != nil }
}

/// Keeps the date the queue armed; the test fires the queue itself.
private nonisolated final class HandFiredWakeUpTimer: MainWakeUpTimer, Sendable {
    private let armed = Mutex<UInt64?>(nil)

    var armedDate: UInt64? {
        get { armed.withLock { $0 } }
        set { armed.withLock { $0 = newValue } }
    }

    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) { armedDate = date }
    func park() { armedDate = nil }
}

/// A fake clock in ns: the queue reads it from any thread, only the test's main actor moves it.
private nonisolated final class RigUptime: Sendable {
    private let value: Atomic<UInt64>

    init(_ start: UInt64) {
        value = Atomic(start)
    }

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}

private final class RigLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
