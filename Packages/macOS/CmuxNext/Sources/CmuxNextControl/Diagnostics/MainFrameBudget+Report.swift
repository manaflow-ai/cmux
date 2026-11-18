public import CmuxNextSettings
public import CmuxNextWakeups

extension MainFrameBudget {
    /// The `debug.main_budget` report: frames seen, injected input waiting, and per budgeted class
    /// its budget, tasks run, input yields, over-budget deferrals, tasks run on idle frame time past
    /// its share, over-budget tasks, longest task and the most it spent in one frame; the input checks
    /// and the render passes (before-waiting phase) with their longest times; background tasks held for a frame
    /// with idle time; and `owners`: every task's own time by owner, all classes, the unbudgeted store drain
    /// (`daemon.store.drain`) too, largest total first (count, over_8ms, total_ms, p50_ms, p95_ms, p99_ms, max_ms;
    /// plans/cmux-next/main-thread-scheduling.md G3 and G4).
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
                "render_passes": JSONValue(stats.renderPasses), "waited_for_idle_frame": JSONValue(stats.waitedForIdleFrame),
                "max_render_pass_ms": .number(Double(stats.maxRenderPassNanos) / 1_000_000),
                "owners": .array(ownerTimes.map(\.report))]
    }
}

extension MainFrameBudget.OwnerTimes {
    /// One `owners` row of `debug.main_budget`.
    var report: JSONValue {
        let ms = { (nanos: UInt64) in JSONValue.number(Double(nanos) / 1_000_000) }
        return ["owner": .string(owner), "count": JSONValue(count), "over_8ms": JSONValue(over8msCount), "total_ms": ms(totalNanos),
                "p50_ms": ms(p50Nanos), "p95_ms": ms(p95Nanos), "p99_ms": ms(p99Nanos), "max_ms": ms(maxNanos)]
    }
}
