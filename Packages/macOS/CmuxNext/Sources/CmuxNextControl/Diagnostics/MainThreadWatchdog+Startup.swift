import Darwin
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextWakeups

/// The launch's part of the watchdog: `main()` makes it first and starts it before
/// LaunchWarmup, so a launch stall is listed from the first statement on; each stall before startup
/// completes names its launch phase and startup task (``startupTasks``, `startup_phase` and
/// `startup_task` in `debug.hangs`).
///
/// `main()` runs before the main run loop first runs, so the run-loop heartbeat cannot split it into
/// turns. Each of its launch steps is its own turn instead, as Chrome watches each task in its own
/// scope (`base/threading/hang_watcher.h`, `WatchHangsInScope`). AppKit sends
/// `applicationDidFinishLaunching` from inside `-[NSApplication run]`, in a run-loop turn the heartbeat
/// already opened: from the first heartbeat on, a step only changes the tag.
extension MainThreadWatchdog {
    /// Ends the main thread's work in progress and starts the next, for `main()`'s launch steps before
    /// the main run loop first runs: a stall of the work that ends is recorded now. It is no run-loop
    /// wake: ``mainRunLoopWakes`` and the busy watchdog do not see it. After the first heartbeat it does
    /// nothing, so a run-loop turn is never split. Main thread only.
    @MainActor
    public func beginStartupTurn() {
        guard running.load(ordering: .relaxed), !runLoopEntered.load(ordering: .relaxed),
              !mainAsleep.load(ordering: .acquiring) else { return }
        let now = uptime()
        stamp(now: now, cpu: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), endingWork: true)
        turnStartNanos.store(now, ordering: .relaxed)
    }

    /// One launch step of `main()`: a new turn (``beginStartupTurn()``) tagged `name` until the next step.
    @MainActor
    public func startupStep(_ name: StaticString) {
        beginStartupTurn()
        startupTasks?.step(name)
    }

    /// AppKit called `applicationDidFinishLaunching`: the critical phase begins in the step
    /// `app.did_finish_launching`, which the startup scheduler's critical tasks run inside. It only
    /// changes the tag: the run-loop turn it is called in stays one turn (``beginStartupTurn()``).
    @MainActor
    public func beginCriticalPhase() {
        beginStartupTurn()
        startupTasks?.appFinishedLaunching()
        startupTasks?.step("app.did_finish_launching")
    }

    /// The running launch step ended (the end of `applicationDidFinishLaunching`): stalls from here
    /// name a startup task only while the startup scheduler runs one.
    @MainActor
    public func endStartupStep() {
        startupTasks?.endStep()
    }
}

/// A ``StartupTaskTag`` reading as the watchdog thread publishes it while the main thread is suspended:
/// two words, no allocation. ``details`` turns it into the stall record's fields after the stall.
struct StartupStallTag: Equatable {
    /// The packed task word (``StartupTaskTag/Reading/packedTask``).
    let task: UInt64
    /// The scheduler phase's raw value shifted left once, with `inMain` in the low bit.
    let state: UInt8

    init(task: UInt64, state: UInt8) {
        (self.task, self.state) = (task, state)
    }

    /// The tag of `reading`; nil (a watchdog with no tag) carries no startup fields.
    init(_ reading: StartupTaskTag.Reading?) {
        let reading = reading ?? StartupTaskTag.Reading(packedTask: 0, phase: .complete, inMain: false)
        self.init(task: reading.packedTask, state: UInt8(truncatingIfNeeded: reading.phase.rawValue) << 1 | (reading.inMain ? 1 : 0))
    }

    /// The reading this tag holds.
    var reading: StartupTaskTag.Reading {
        StartupTaskTag.Reading(packedTask: task, phase: StartupTaskLog.Phase(rawValue: Int(truncatingIfNeeded: state >> 1)) ?? .complete, inMain: state & 1 == 1)
    }

    /// `startup_phase` (``StartupTaskTag/Reading/stallPhase``) and, when a task ran, `startup_task`;
    /// none once startup completed or quit began. Main thread, after the stall.
    var details: [String: JSONValue] {
        let reading = self.reading
        guard let phase = reading.stallPhase else { return [:] }
        var details: [String: JSONValue] = ["startup_phase": .string(phase)]
        if let task = reading.taskName { details["startup_task"] = .string(task) }
        return details
    }
}
