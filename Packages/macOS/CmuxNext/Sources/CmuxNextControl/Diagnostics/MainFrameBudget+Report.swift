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
