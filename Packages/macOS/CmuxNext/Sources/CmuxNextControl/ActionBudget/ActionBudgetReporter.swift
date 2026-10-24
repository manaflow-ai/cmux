public import CmuxNextActions
public import CmuxNextSettings
import os

/// The off-main half of the per-action budget: folds every run an ``ActionBudgetMonitor`` hands
/// over (in batches) into ``ledger``'s latency histograms (the Release report's fields), and in a
/// Debug build writes one log line per over-budget run (``ActionBudgetLogLine``) with the
/// main-thread work the watchdog sampled during it.
///
/// None of it runs on the action's turn: the monitor hands runs over after the commit they are
/// timed to, and this reads them on its own tasks. Built once by the App's control wiring
/// (`AppControl`).
///
/// ```swift
/// let reporter = ActionBudgetReporter(monitor: services.actionBudget, naming: ActionReportNaming(catalog: ids),
///                                     stalls: watchdog.log, threshold: watchdog.configuration.threshold, logsRuns: isDebug)
/// let fields = await reporter.counts().json
/// ```
public final class ActionBudgetReporter: Sendable {
    /// Every run's latency per report id and entrypoint.
    public let ledger: ActionBudgetLedger
    private let monitor: ActionBudgetMonitor
    private let tasks: [Task<Void, Never>]

    /// Starts reading `monitor`'s runs.
    ///
    /// - Parameters:
    ///   - monitor: The per-action budget.
    ///   - naming: The report id of each action (no user text in a report).
    ///   - stalls: The main-thread watchdog's stall log, for the Debug line's stack; nil without a
    ///     watchdog.
    ///   - threshold: The watchdog's stall threshold (a shorter run has no sample).
    ///   - logsRuns: Write the Debug log line per over-budget run (Debug builds). It keeps the
    ///     real action id: the log stays on this Mac.
    @MainActor
    public init(monitor: ActionBudgetMonitor, naming: ActionReportNaming, stalls: HangLog?, threshold: Duration?, logsRuns: Bool) {
        let ledger = ActionBudgetLedger(budgetMilliseconds: Double(monitor.budgetNanos) / 1_000_000, naming: naming)
        self.ledger = ledger
        self.monitor = monitor
        let batches = monitor.batches()
        var tasks = [Task.detached(priority: .utility) {
            for await batch in batches { await ledger.note(batch) }
        }]
        if logsRuns {
            let slow = monitor.samples(everyRun: false)
            tasks.append(Task.detached(priority: .utility) {
                let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "action.budget")
                for await sample in slow {
                    // The watchdog records the run's stall in the same before-waiting pass as the
                    // run's commit, after it (its observer's order is last). A main-actor job runs
                    // only after that pass, so once it returns the stall is in the log: an ordering
                    // signal, no work on the main thread.
                    await MainActor.run {}
                    let line = ActionBudgetLogLine(sample: sample, stalls: stalls?.records() ?? [],
                                                   threshold: stalls == nil ? nil : threshold)
                    logger.notice("\(line.text, privacy: .public)")
                }
            })
        }
        self.tasks = tasks
    }

    deinit {
        for task in tasks { task.cancel() }
    }

    /// The report's counters now: the runs since the monitor's last batch are folded in first, so
    /// none recorded before the call is missing (a batch already handed over but not yet folded
    /// lands in the next call).
    public func counts() async -> ActionBudgetCounts {
        let (unbatched, dropped) = await MainActor.run { [monitor] in (monitor.takeUnbatched(), monitor.droppedRunCount) }
        await ledger.note(unbatched)
        return await ledger.snapshot(dropped: Int(clamping: dropped))
    }

    /// `debug.action_budget`: the report's counters and the newest runs from the monitor's ring
    /// (with their real ids: a Debug method).
    public var method: ControlMethod {
        .async("debug.action_budget") { [self] call in
            let limit = call.params["limit"]?.intValue ?? 64
            let (recent, over, droppedSamples) = await MainActor.run { [monitor] in
                (monitor.recent(limit), monitor.overBudgetCount, monitor.droppedSampleCount)
            }
            guard case .object(var members) = await counts().json else { return .null }
            members["over_budget_recorded"] = JSONValue(Int(clamping: over))
            members["samples_dropped"] = JSONValue(Int(clamping: droppedSamples))
            members["recent"] = .array(recent.map { sample in
                .object([
                    "sequence": JSONValue(Int(clamping: sample.sequence)),
                    "id": .string(sample.id.rawValue),
                    "entrypoint": .string(sample.entrypoint.rawValue),
                    "commit_ms": .number(sample.milliseconds),
                    "input_age_ms": .number(sample.inputAgeMilliseconds),
                    "outcome": .string(String(describing: sample.outcome)),
                    "start_uptime_ns": .number(Double(sample.startUptimeNanos)),
                ])
            })
            return .object(members)
        }
    }
}
