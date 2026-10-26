public import CmuxNextSettings
public import CmuxNextWakeups

extension MainFrameBudget {
    /// The `debug.main_budget` report: frames seen, injected input waiting, and per budgeted class
    /// its budget, tasks run, input yields, input-response yields, typing-burst rate waits, over-budget deferrals, tasks run on idle frame time past
    /// its share, over-budget tasks, longest task and the most it spent in one frame; the input checks
    /// and the render passes (before-waiting phase) with their longest times; input responses that hit
    /// the 100 ms cap and the longest input response; with a starvation guard, its `render_starvation` part;
    /// and the main run loop's turns (``MainTurnMeter``): the turn and task time distributions, the share of
    /// busy time no span or render phase covers, and the turns with the most of it. This folds it all on the
    /// main thread; the control method folds the turns off it (``reportParts``).
    public var report: JSONValue {
        let parts = reportParts
        return parts.turns.report(merging: parts.fields)
    }

    /// The main thread's part of ``report``: the budget's own fields and a copy of the turn counters,
    /// whose percentiles and top turns ``MainTurnMeter/Snapshot/report(merging:)`` folds on any thread.
    public var reportParts: (fields: [String: JSONValue], turns: MainTurnMeter.Snapshot) {
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
        var fields: [String: JSONValue] = [
            "frames": JSONValue(stats.frames), "classes": .object(classes), "pending_input": JSONValue(board.pendingInputCount),
            "input_checks": JSONValue(stats.inputChecks), "max_input_check_ms": .number(Double(stats.maxInputCheckNanos) / 1_000_000),
            "render_passes": JSONValue(stats.renderPasses), "max_render_pass_ms": .number(Double(stats.maxRenderPassNanos) / 1_000_000),
            "input_response_cap_hits": JSONValue(stats.inputResponseCapHits),
            "max_input_response_ms": .number(Double(stats.maxInputResponseNanos) / 1_000_000),
        ]
        if let starvation { fields["render_starvation"] = Self.starvationReport(starvation) }
        return (fields, turns.snapshot())
    }

    /// The rendering starvation guard's part: whether it holds work, the late periods it reported,
    /// the longest gap, and the work it held (per budgeted class, and the CEF pump's slices).
    private static func starvationReport(_ starvation: RenderStarvationGuard) -> JSONValue {
        let stats = starvation.stats
        var held: [String: JSONValue] = [:]
        for (index, workClass) in MainWorkClass.budgeted.enumerated() {
            held[workClass.description] = JSONValue(stats.heldTasks[checked: index] ?? 0)
        }
        return ["holds_work": .bool(starvation.holdsWork), "events": JSONValue(stats.events),
                "max_gap_ms": .number(stats.maxGap * 1000), "held_tasks": .object(held), "held_slices": JSONValue(stats.heldSlices)]
    }
}

nonisolated extension MainTurnMeter.Snapshot {
    /// `fields` with the turn fields added (``reportFields``; a field already there wins).
    public func report(merging fields: [String: JSONValue]) -> JSONValue {
        .object(fields.merging(reportFields) { current, _ in current })
    }

    /// The turn fields of `debug.main_budget`: `turn_ms` and `task_ms` (count, p50, p95, p99 and max in
    /// milliseconds, each percentile its bucket's upper edge; `turn_ms` adds the nested and over-4 ms
    /// counts and the split totals), `unattributed_share` and `top_unattributed_turns`, longest first.
    public var reportFields: [String: JSONValue] {
        var turnFields = Self.distribution(turnBuckets, count: turns, max: maxTurnNanos)
        turnFields["nested"] = JSONValue(nestedTurns)
        turnFields["over_4ms"] = JSONValue(turnsOverStall)
        turnFields["scheduled_total"] = Self.ms(scheduledNanos)
        turnFields["render_total"] = Self.ms(renderNanos)
        turnFields["input_total"] = Self.ms(inputNanos)
        turnFields["unattributed_total"] = Self.ms(unattributedNanos)
        return [
            "turn_ms": .object(turnFields),
            "task_ms": .object(Self.distribution(taskBuckets, count: tasks, max: maxTaskNanos)),
            "unattributed_share": .number(unattributedShare),
            "top_unattributed_turns": .array(longestUnattributed.map(Self.turn)),
        ]
    }

    private static func distribution(_ buckets: [UInt32], count: Int, max: UInt64) -> [String: JSONValue] {
        ["count": JSONValue(count), "max": ms(max), "p50": ms(percentile(0.5, of: buckets, max: max)),
         "p95": ms(percentile(0.95, of: buckets, max: max)), "p99": ms(percentile(0.99, of: buckets, max: max))]
    }

    private static func turn(_ turn: MainTurnMeter.TopTurn) -> JSONValue {
        ["turn_ms": ms(turn.turnNanos), "unattributed_ms": ms(turn.unattributedNanos), "scheduled_ms": ms(turn.scheduledNanos),
         "render_ms": ms(turn.renderNanos), "input_ms": ms(turn.inputNanos), "nested": .bool(turn.nested),
         "end_uptime_ms": ms(turn.endNanos)]
    }

    private static func ms(_ nanos: UInt64) -> JSONValue { .number(Double(nanos) / 1_000_000) }
}
