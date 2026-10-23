import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups

/// `debug.main_budget`: the main-thread scheduler's per-frame budget counters, per budgeted class.
@MainActor
struct DebugMainBudget {
    static func report(_ budget: MainFrameBudget) -> JSONValue {
        let stats = budget.stats
        var classes: [String: JSONValue] = [:]
        for (index, workClass) in MainWorkClass.budgeted.enumerated() {
            classes[workClass.description] = [
                "budget_ms": .number(Double(MainFrameBudget.nanos(budget.budgets.budget(workClass) ?? .zero)) / 1_000_000),
                "tasks": JSONValue(stats.tasks[index]),
                "yielded_to_input": JSONValue(stats.yieldedToInput[index]),
                "deferred_over_budget": JSONValue(stats.deferredOverBudget[index]),
                "over_budget_tasks": JSONValue(stats.overBudgetTasks[index]),
                "max_task_ms": .number(Double(stats.maxTaskNanos[index]) / 1_000_000),
                "max_frame_ms": .number(Double(stats.maxFrameNanos[index]) / 1_000_000),
            ]
        }
        return ["frames": JSONValue(stats.frames), "classes": .object(classes),
                "pending_input": JSONValue(budget.board.pendingInputCount)]
    }
}
