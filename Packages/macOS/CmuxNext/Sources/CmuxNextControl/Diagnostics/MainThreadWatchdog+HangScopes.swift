public import CmuxNextSettings
public import CmuxNextWakeups
import CmuxNextCompat
import os

/// Hang scopes per class (plans/cmux-next/chrome-parity/p06-scheduler.md, "Attribution"): Chrome's
/// `HangWatcher` (base/threading/hang_watcher.h) gives each `WatchHangsInScope` a deadline and reports a
/// scope still running past it with `DumpWithoutCrashing`. Here every scheduled main-thread task is a
/// scope with its class's deadline (``MainTaskBoard/hangScopeNanos(_:)``); a task past it is recorded
/// once in ``taskHangs`` with its owner, class, posting location, turn and stack, in every build, and
/// nothing crashes. Nested run loops (menus, modal panels, drags) invalidate the scopes
/// (``MainTaskBoard/HangScope/isValid``), as Chrome's `InvalidateActiveExpectations` does.
extension MainThreadWatchdog {
    /// What a hang names: the scheduled task the watchdog's sample caught, with its owner, class and
    /// posting location, and how long the main run-loop turn had run. No task: `unattributed`.
    public struct HangAttribution: Sendable, Equatable {
        /// The owner and class of work no scheduled task covers.
        public static let unattributed = "unattributed"

        /// The scheduled task that ran; nil when none did (AppKit's own work, an unclassified job).
        public var task: MainTaskBoard.Task?
        /// How long the run-loop turn had run when sampled, in nanoseconds.
        public var turnNanos: UInt64

        public init(task: MainTaskBoard.Task?, turnNanos: UInt64) {
            self.task = task
            self.turnNanos = turnNanos
        }

        /// The task's owner, or ``unattributed``.
        public var owner: String { task?.owner ?? Self.unattributed }
        /// The task's class, or ``unattributed``.
        public var taskClass: String { task?.workClass.description ?? Self.unattributed }
        /// Where the task was posted (`Module/File.swift:line`); nil for an unposted task or none.
        public var location: String? { task?.postedFrom?.description }
        /// The turn in milliseconds.
        public var turnMilliseconds: Double { Double(turnNanos) / 1_000_000 }

        /// The record fields: `task_owner`, `task_class`, `task_location` (when posted) and `turn_ms`.
        public var details: [String: JSONValue] {
            var details: [String: JSONValue] = ["task_owner": .string(owner), "task_class": .string(taskClass),
                                                "turn_ms": .number(turnMilliseconds)]
            if let location { details["task_location"] = .string(location) }
            return details
        }
    }

    /// Watchdog thread, at each check while the main thread runs: the task diagnostics mode's
    /// over-budget sample, then the running task's hang scope. Returns when to look again (the
    /// sooner of the two), or nil.
    func checkRunningTask(now: UInt64, sampled: inout UInt64, reported: inout UInt64) -> UInt64? {
        let budgetDue = sampleTaskOverBudget(now: now, sampled: &sampled)
        guard let scopeDue = checkHangScope(now: now, reported: &reported) else { return budgetDue }
        return budgetDue.map { min($0, scopeDue) } ?? scopeDue
    }

    /// Watchdog thread: once the running task is past its hang deadline in a valid scope, samples the
    /// main thread and records the task in ``taskHangs`` (once per task; `reported` holds the last one).
    /// Returns the deadline of a task that has not reached it yet, to wait for; else nil. Reads the
    /// board's atomics only while the main thread is suspended, and allocates only for a report.
    func checkHangScope(now: UInt64, reported: inout UInt64) -> UInt64? {
        guard let board = boardSink.withLock({ $0 }) else { return nil }
        let scope = board.hangScope
        guard scope.packed != 0, scope.packed != reported, scope.isValid else { return nil }
        guard scope.isOverdue(at: now) else { return scope.deadlineNanos }
        // The read above ran beside the main thread; the one made while it is suspended decides, and the
        // record is built from it.
        var confirmed = scope
        let addresses = taskSampler.withLock({ $0 })?.sample { _ in confirmed = board.hangScope } ?? []
        guard confirmed.packed == scope.packed, confirmed.isValid else { return nil }
        guard confirmed.isOverdue(at: now) else { return confirmed.deadlineNanos }
        reported = confirmed.packed
        guard let task = board.task(confirmed) else { return nil }
        let attribution = HangAttribution(task: task, turnNanos: turnNanos(at: now))
        var details = Self.details(of: task)
        details["turn_ms"] = .number(attribution.turnMilliseconds)
        details["hang_deadline_ms"] = .number(Double(confirmed.deadlineNanos &- confirmed.startNanos) / 1_000_000)
        let record = taskHangs.append(startUptimeNanos: confirmed.startNanos, duration: .nanoseconds(Int64(clamping: now &- confirmed.startNanos)),
                                      addresses: addresses, kind: .taskHang, details: details)
        if configuration.logStalls {
            logger.error("main-thread task past its hang deadline: \(attribution.owner, privacy: .public) (\(attribution.taskClass, privacy: .public)) at \(attribution.location ?? "-", privacy: .public), \(record.duration.fractionalMilliseconds, format: .fixed(precision: 0)) ms (debug.hangs task_hangs)")
        }
        return nil
    }

    /// The hang attribution of the scope read while the main thread was suspended (`scope`), resolved
    /// after it resumed; ``HangAttribution/task`` nil when no task ran or the main thread moved on.
    func hangAttribution(_ scope: MainTaskBoard.HangScope, stillBlocked: Bool, now: UInt64) -> HangAttribution {
        HangAttribution(task: stillBlocked ? boardSink.withLock({ $0 })?.task(scope) : nil, turnNanos: turnNanos(at: now))
    }

    /// How long the main run-loop turn in progress has run at `now`.
    private func turnNanos(at now: UInt64) -> UInt64 {
        let start = turnStartNanos.load(ordering: .relaxed)
        return now > start ? now - start : 0
    }
}
