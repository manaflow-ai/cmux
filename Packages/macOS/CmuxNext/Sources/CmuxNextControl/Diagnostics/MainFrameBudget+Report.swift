public import CmuxNextSettings
public import CmuxNextWakeups

extension MainFrameBudget {
    /// The `debug.main_budget` report: frames seen, injected input waiting, and per budgeted class
    /// its budget, tasks run, input yields, input-response yields, typing-burst rate waits, over-budget deferrals, tasks run on idle frame time past
    /// its share, over-budget tasks, longest task and the most it spent in one frame; the input checks
    /// and the render passes (before-waiting phase) with their longest times; input responses that hit
    /// the 100 ms cap and the longest input response.
    public var report: JSONValue {
        let stats = stats
        var classes: [String: JSONValue] = [:]
        for (index, workClass) in MainWorkClass.budgeted.enumerated() {
            classes[workClass.description] = [
                "budget_ms": .number(Double(Self.nanos(budgets.budget(workClass) ?? .zero)) / 1_000_000),
                "tasks": JSONValue((stats.tasks[checked: index] ?? 0)),
                "yielded_to_input": JSONValue((stats.yieldedToInput[checked: index] ?? 0)),
                "yielded_to_input_response": JSONValue((stats.yieldedToInputResponse[checked: index] ?? 0)),
                "waited_for_burst_slot": JSONValue((stats.waitedForBurstSlot[checked: index] ?? 0)),
                "deferred_over_budget": JSONValue((stats.deferredOverBudget[checked: index] ?? 0)),
                "idle_tasks": JSONValue((stats.idleTasks[checked: index] ?? 0)),
                "over_budget_tasks": JSONValue((stats.overBudgetTasks[checked: index] ?? 0)),
                "max_task_ms": .number(Double((stats.maxTaskNanos[checked: index] ?? 0)) / 1_000_000),
                "max_frame_ms": .number(Double((stats.maxFrameNanos[checked: index] ?? 0)) / 1_000_000),
            ]
        }
        return ["frames": JSONValue(stats.frames), "classes": .object(classes), "pending_input": JSONValue(board.pendingInputCount),
                "input_checks": JSONValue(stats.inputChecks), "max_input_check_ms": .number(Double(stats.maxInputCheckNanos) / 1_000_000),
                "render_passes": JSONValue(stats.renderPasses), "max_render_pass_ms": .number(Double(stats.maxRenderPassNanos) / 1_000_000),
                "input_response_cap_hits": JSONValue(stats.inputResponseCapHits),
                "max_input_response_ms": .number(Double(stats.maxInputResponseNanos) / 1_000_000)]
    }
}

extension MainTaskBoard {
    /// The whole `debug.main_budget` reply: the budget's ``MainFrameBudget/report``, read on the
    /// main actor, plus `owners`, per owner and class the wait and run percentiles, node states and
    /// posting sites of the finished tasks (``MainOwnerLedger``, highest run p99 first), and
    /// `owner_ledger`, how many records it folded, dropped and has pending. The ledger is folded
    /// here, off the main thread, so the main thread never takes its lock.
    ///
    /// - Parameters:
    ///   - budget: The budget whose board this is.
    ///   - reset: Clears the budget's counters and the ledger after reading them.
    @concurrent
    public func mainBudgetReport(_ budget: MainFrameBudget, reset: Bool) async -> JSONValue {
        let snapshot = ownerSnapshot()
        if reset { ledger.reset() }
        let classes = await MainActor.run {
            let report = budget.report
            if reset { budget.resetStats() }
            return report
        }
        guard case .object(var fields) = classes else { return classes }
        fields["owners"] = .array(snapshot.owners.map(\.report))
        fields["owner_ledger"] = .object([
            "recorded": .number(Double(snapshot.recorded)), "dropped": .number(Double(snapshot.dropped)), "pending": JSONValue(snapshot.pending),
        ])
        return .object(fields)
    }
}

extension MainOwnerLedger.Owner {
    /// One `owners` row: owner, class, tasks, wait and run percentiles in milliseconds, total run
    /// time, tasks per node state and the top posting sites.
    var report: JSONValue {
        var nodes: [String: JSONValue] = [:]
        for (state, count) in self.nodes { nodes[state.description] = JSONValue(count) }
        let postedFrom: [JSONValue] = sites.map { site in ["location": .string(site.location), "tasks": JSONValue(site.tasks)] }
        let row: [String: JSONValue] = [
            "owner": .string(owner), "class": .string(workClass.description), "tasks": JSONValue(tasks), "wait": wait.report,
            "run": run.report, "run_total_ms": .number(Double(runTotalNanos) / 1_000_000), "nodes": .object(nodes),
            "posted_from": .array(postedFrom),
        ]
        return .object(row)
    }
}

extension MainOwnerLedger.Distribution {
    /// `{count, p50_ms, p95_ms, p99_ms, max_ms}`.
    var report: JSONValue {
        [
            "count": JSONValue(count), "p50_ms": .number(Double(p50Nanos) / 1_000_000), "p95_ms": .number(Double(p95Nanos) / 1_000_000),
            "p99_ms": .number(Double(p99Nanos) / 1_000_000), "max_ms": .number(Double(maxNanos) / 1_000_000),
        ]
    }
}
