public import CmuxNextSettings
import CmuxNextCompat
public import CmuxNextWakeups
import Darwin
import Foundation

extension MainThreadWatchdog {
    /// The environment variable that turns on the task diagnostics mode (``recordsTaskBudgets(environment:)``).
    public static let taskDiagnosticsVariable = "CMUX_NEXT_MAIN_TASK_DIAGNOSTICS"

    /// Whether a launch records scheduled tasks that run past their class budget, with a stack:
    /// only in the explicit task diagnostics mode (`CMUX_NEXT_MAIN_TASK_DIAGNOSTICS=1`). It
    /// perturbs what it measures (one cross-thread wake per task, a main-thread suspension per
    /// over-budget task), so no bench number is taken with it on, and lowering the stall threshold
    /// (`CMUX_NEXT_HANG_THRESHOLD_MS`) does not turn it on. Every launch names the running task in
    /// its stall records.
    ///
    /// - Parameter environment: The launch's environment (the app passes its process environment).
    public static func recordsTaskBudgets(environment: [String: String]) -> Bool {
        environment[taskDiagnosticsVariable] == "1"
    }

    /// Reads the main-thread scheduler's board (``MainTaskBoard``): every stall record from now on
    /// names the scheduled task its sample caught (`task_owner`, `task_class`, `task_budget_ms`,
    /// `task_sequence`, and `task_started_ms`: when that task began, relative to the stall's start;
    /// negative when it began before the stall). With `recordTaskBudgets`, every
    /// scheduled task that ran past its class's per-frame budget is also recorded in ``overBudget``,
    /// with a stack sampled the moment it crossed the budget: the board wakes this thread at each
    /// task start so it can sample in time (one kqueue user event per task, `MainThreadWatchdogAlarm`).
    ///
    /// Call it on the main thread (the task sampler samples the calling thread).
    ///
    /// - Parameters:
    ///   - board: The board of the app's ``MainFrameBudget`` (its ``MainWorkScheduler``).
    ///   - recordTaskBudgets: Record over-budget tasks (``recordsTaskBudgets(environment:)``).
    @MainActor
    public func attach(board: MainTaskBoard, recordTaskBudgets: Bool) {
        boardSink.withLock { $0 = board }
        guard recordTaskBudgets else { return }
        // Its own buffer (a stall's sample stays in the stall sampler until the main thread copies
        // it); only this mode samples tasks, so only this mode allocates it.
        if configuration.sampleStacks { taskSampler.withLock { $0 = ThreadStackSampler(thread: mach_thread_self()) } }
        board.setTaskStartHook { [weak self] in self?.wakeForTask() }
        board.setOverBudgetSink { [weak self] task, nanos in self?.recordOverBudget(task, nanos: nanos) }
        taskDiagnostics.store(true, ordering: .releasing)
    }

    /// The stall record fields for `task`.
    static func details(of task: MainTaskBoard.Task) -> [String: JSONValue] {
        [
            "task_owner": .string(task.owner),
            "task_class": .string(task.workClass.description),
            "task_budget_ms": .number(Double(task.budgetNanos) / 1_000_000),
            "task_sequence": JSONValue(Int(clamping: task.sequence)),
        ]
    }

    /// Main thread, at the end of an over-budget task: one ``overBudget`` record with the stack
    /// sampled while it ran past the budget (empty when it ended before the sample).
    private func recordOverBudget(_ task: MainTaskBoard.Task, nanos: UInt64) {
        let packed = Self.pack(task)
        let addresses = taskSamples.withLock { samples -> [UInt] in
            guard let index = samples.firstIndex(where: { $0.packed == packed }) else { return [] }
            return samples.remove(at: index).addresses
        }
        let details = Self.details(of: task)
        overBudget.append(startUptimeNanos: task.startNanos, duration: .nanoseconds(Int64(clamping: nanos)), addresses: addresses,
                          kind: .overBudget, details: details)
    }

    /// The packed identity the board publishes for `task` (class, owner index is not kept in
    /// ``MainTaskBoard/Task``, so the sequence and start tell tasks apart).
    static func pack(_ task: MainTaskBoard.Task) -> UInt64 {
        UInt64(clamping: task.sequence) ^ task.startNanos << 20
    }

    /// Watchdog thread: when the running scheduled task has passed its budget and was not sampled
    /// yet, samples the main thread once and keeps the stack for the task's over-budget record.
    /// Returns when the running task will cross its budget (to wait for), or nil.
    func sampleTaskOverBudget(now: UInt64, sampled: inout UInt64) -> UInt64? {
        guard taskDiagnostics.load(ordering: .acquiring) else { return nil }
        guard let sampler = taskSampler.withLock({ $0 }), let board = boardSink.withLock({ $0 }), board.hasTaskStartHook else { return nil }
        let running = board.runningPacked
        guard running.packed != 0, running.budgetNanos > 0, let task = board.task(packed: running.packed, startNanos: running.startNanos,
                                                                                     budgetNanos: running.budgetNanos) else { return nil }
        let key = Self.pack(task)
        guard key != sampled else { return nil }
        let due = running.startNanos &+ running.budgetNanos
        guard now >= due else { return due }
        sampled = key
        // The task may have ended since the check: the sample then shows later work, and the
        // board's over-budget record (which only a task past its budget gets) never asks for it.
        let addresses = sampler.sample()
        guard board.runningPacked.packed == running.packed else { return nil }
        taskSamples.withLock { samples in
            samples.append((key, addresses))
            if samples.count > 8 { samples.removeFirst() }
        }
        return nil
    }
}
