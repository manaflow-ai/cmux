public import CmuxNextSettings
public import CmuxNextWakeups

extension MainFrameBudget {
    /// The `debug.main_budget` report: frames seen, injected input waiting, and per budgeted class
    /// its budget, tasks run, input yields, over-budget deferrals, tasks run on idle frame time past
    /// its share, over-budget tasks, longest task and the most it spent in one frame; the input checks
    /// and the render passes (before-waiting phase) with their longest times.
    public var report: JSONValue {
        let stats = stats
        var classes: [String: JSONValue] = [:]
        for (index, workClass) in MainWorkClass.budgeted.enumerated() {
            classes[workClass.description] = [
                "budget_ms": .number(Double(Self.nanos(budgets.budget(workClass) ?? .zero)) / 1_000_000),
                "tasks": JSONValue((stats.tasks[checked: index] ?? 0)),
                "yielded_to_input": JSONValue((stats.yieldedToInput[checked: index] ?? 0)),
                "deferred_over_budget": JSONValue((stats.deferredOverBudget[checked: index] ?? 0)),
                "idle_tasks": JSONValue((stats.idleTasks[checked: index] ?? 0)),
                "over_budget_tasks": JSONValue((stats.overBudgetTasks[checked: index] ?? 0)),
                "max_task_ms": .number(Double((stats.maxTaskNanos[checked: index] ?? 0)) / 1_000_000),
                "max_frame_ms": .number(Double((stats.maxFrameNanos[checked: index] ?? 0)) / 1_000_000),
            ]
        }
        return ["frames": JSONValue(stats.frames), "classes": .object(classes), "pending_input": JSONValue(board.pendingInputCount),
                "input_checks": JSONValue(stats.inputChecks), "max_input_check_ms": .number(Double(stats.maxInputCheckNanos) / 1_000_000),
                "render_passes": JSONValue(stats.renderPasses), "max_render_pass_ms": .number(Double(stats.maxRenderPassNanos) / 1_000_000)]
    }
}

extension IdleScheduler {
    /// The `idle` member of the `debug.main_budget` report: periods, tasks run, promoted and
    /// dropped, periods ended by input or higher-class work, timer fires and tasks queued.
    public var report: JSONValue {
        let stats = stats
        return ["long_periods": JSONValue(stats.longPeriods), "short_periods": JSONValue(stats.shortPeriods),
                "tasks": JSONValue(stats.tasks), "promoted": JSONValue(stats.promoted), "dropped": JSONValue(stats.dropped),
                "ended_by_input": JSONValue(stats.endedByInput), "ended_by_higher_work": JSONValue(stats.endedByHigherWork),
                "timer_fires": JSONValue(stats.timerFires), "queued": JSONValue(count)]
    }
}

extension MainWorkScheduler {
    /// The `debug.main_budget` report: the budget's, with the idle class's under `idle`.
    public var budgetReport: JSONValue {
        var report = budget.report.objectValue ?? [:]
        report["idle"] = idle.report
        return .object(report)
    }

    /// Clears the budget's and the idle class's counters (`debug.main_budget reset`).
    public func resetBudgetStats() {
        budget.resetStats()
        idle.resetStats()
    }
}
