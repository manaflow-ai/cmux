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
        for (index, workClass) in Stats.classes.enumerated() {
            classes[workClass.description] = [
                "budget_ms": .number(Double(Self.nanos(shares.budget(workClass) ?? .zero)) / 1_000_000),
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
        let turnStats = budgetTurnStats
        fields["placement"] = .string(placement == .afterCommit ? "after_commit" : "in_tick")
        fields["budget_turns"] = ["turns": JSONValue(turnStats.turns), "past_deadline": JSONValue(turnStats.pastDeadline),
                                  "max_overrun_ms": .number(Double(turnStats.maxOverrunNanos) / 1_000_000)]
        return (fields, turns.snapshot())
    }

    /// The rendering starvation guard's part: whether it holds work, the late periods it reported,
    /// the longest gap, and the work it held (per budgeted class, and the CEF pump's slices).
    private static func starvationReport(_ starvation: RenderStarvationGuard) -> JSONValue {
        let stats = starvation.stats
        var held: [String: JSONValue] = [:]
        for (index, workClass) in MainFrameBudget.Stats.classes.enumerated() {
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
        var tickFields = Self.distribution(tickTurns)
        tickFields["with_budgeted_tasks"] = JSONValue(tickTurnsWithBudgetedTasks)
        return [
            "turn_ms": .object(turnFields),
            "tick_turn_ms": .object(tickFields),
            "budget_turn_ms": .object(Self.distribution(budgetTurns)),
            "task_ms": .object(Self.distribution(taskBuckets, count: tasks, max: maxTaskNanos)),
            "unattributed_share": .number(unattributedShare),
            "top_unattributed_turns": .array(longestUnattributed.map(Self.turn)),
        ]
    }

    private static func distribution(_ buckets: [UInt32], count: Int, max: UInt64) -> [String: JSONValue] {
        ["count": JSONValue(count), "max": ms(max), "p50": ms(percentile(0.5, of: buckets, max: max)),
         "p95": ms(percentile(0.95, of: buckets, max: max)), "p99": ms(percentile(0.99, of: buckets, max: max))]
    }

    private static func distribution(_ turns: KindTurns) -> [String: JSONValue] {
        distribution(turns.buckets, count: turns.count, max: turns.maxNanos)
    }

    private static func turn(_ turn: MainTurnMeter.TopTurn) -> JSONValue {
        ["turn_ms": ms(turn.turnNanos), "unattributed_ms": ms(turn.unattributedNanos), "scheduled_ms": ms(turn.scheduledNanos),
         "render_ms": ms(turn.renderNanos), "input_ms": ms(turn.inputNanos), "nested": .bool(turn.nested),
         "end_uptime_ms": ms(turn.endNanos)]
    }

    private static func ms(_ nanos: UInt64) -> JSONValue { .number(Double(nanos) / 1_000_000) }
}

extension MainTaskBoard {
    /// The whole `debug.main_budget` reply: the budget's ``MainFrameBudget/report`` (its own fields
    /// copied on the main actor, its turn fields folded here from ``MainFrameBudget/reportParts``),
    /// plus `owners`, per owner and class the wait and run percentiles, node states and posting sites
    /// of the finished tasks (``MainOwnerLedger``, highest run p99 first), and `owner_ledger`, how many
    /// records it folded, dropped and has pending. The ledger and the turns are folded here, off the
    /// main thread, so the main thread never takes the ledger's lock.
    ///
    /// - Parameters:
    ///   - budget: The budget whose board this is.
    ///   - idle: The scheduler's idle class, reported under `idle` (``IdleScheduler/report``); nil: no `idle` member.
    ///   - reset: Clears the budget's counters, the idle class's and the ledger after reading them.
    @concurrent
    public func mainBudgetReport(_ budget: MainFrameBudget, idle: IdleScheduler? = nil, reset: Bool) async -> JSONValue {
        let snapshot = ownerSnapshot()
        if reset { ledger.reset() }
        // main-hop-allow: the scheduler's own report; a post would queue the read behind the classes it reports on
        let (parts, idleReport) = await MainActor.run {
            let parts = budget.reportParts
            let idleReport = idle?.report
            if reset {
                budget.resetStats()
                idle?.resetStats()
            }
            return (parts, idleReport)
        }
        var fields = parts.fields.merging(parts.turns.reportFields) { current, _ in current }
        if let idleReport { fields["idle"] = idleReport }
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
