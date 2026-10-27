public import CmuxNextActions
public import CmuxNextSettings
public import CmuxNextWakeups
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
///                                     overBudget: watchdog.overBudget, sampling: MainThreadWatchdog.recordsTaskBudgets(environment: env), logsRuns: isDebug,
///                                     work: services.work, mainWork: services.mainWork)
/// let fields = await reporter.counts().json
/// ```
public final class ActionBudgetReporter: Sendable {
    /// Every run's latency per report id and entrypoint.
    public let ledger: ActionBudgetLedger
    private let monitor: ActionBudgetMonitor
    /// Where the monitor's main-actor counters are read: one automation task per report (a script or the CLI asks).
    private let mainWork: MainWorkScheduler
    private let tasks: [Task<Void, Never>]

    /// Starts reading `monitor`'s runs.
    ///
    /// - Parameters:
    ///   - monitor: The per-action budget.
    ///   - naming: The report id of each action (no user text in a report).
    ///   - overBudget: The main-thread watchdog's over-budget records (``MainThreadWatchdog/overBudget``),
    ///     for the Debug line's stack; nil without a watchdog.
    ///   - sampling: Whether the watchdog samples over-budget tasks (``MainThreadWatchdog/recordsTaskBudgets(environment:)``).
    ///   - logsRuns: Write the Debug log line per over-budget run (Debug builds). It keeps the
    ///     real action id: the log stays on this Mac.
    ///   - work: The app's blocking-work lanes: the Debug line's symbol map is read on its files lane at the
    ///     first stack to resolve, never on this reporter's cooperative-pool task.
    ///   - mainWork: The app's main-thread scheduler: a report reads the monitor in one
    ///     ``BudgetedWorkClass/automation`` task on it, which yields to the person's input (Chrome posts such reads on
    ///     a typed task runner, content/browser/scheduler/browser_task_queues.h).
    ///   - symbolMap: Reads the app's symbol map (``AppSymbolMap/loadMain()``, a file read and an inflate); runs
    ///     on `work`'s files lane, once.
    @MainActor
    public init(monitor: ActionBudgetMonitor, naming: ActionReportNaming, overBudget: HangLog?, sampling: Bool, logsRuns: Bool,
                work: BackgroundWork, mainWork: MainWorkScheduler,
                symbolMap: @escaping @Sendable () -> AppSymbolMap? = { AppSymbolMap.loadMain() }) {
        let ledger = ActionBudgetLedger(budgetMilliseconds: Double(monitor.budgetNanos) / 1_000_000, naming: naming)
        self.ledger = ledger
        self.monitor = monitor
        self.mainWork = mainWork
        let batches = monitor.batches()
        var tasks = [Task.detached(priority: .utility) {
            for await batch in batches { await ledger.note(batch) }
        }]
        if logsRuns {
            let slow = monitor.samples(everyRun: false)
            tasks.append(Task.detached(priority: .utility) {
                let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "action.budget")
                var symbolicator: StackSymbolicator?  // made at the first stack to resolve
                for await sample in slow {
                    // The board ended the run's span (and the watchdog wrote its record) before the
                    // monitor handed the run over, both on the main actor: the record is in the log.
                    let records = overBudget?.records() ?? []
                    if symbolicator == nil, records.contains(where: { !$0.addresses.isEmpty }) {
                        let map = try? await work.run(.bestEffort, mayBlock: .files) { symbolMap() }
                        symbolicator = StackSymbolicator(map: map)
                    }
                    let resolver = symbolicator ?? StackSymbolicator(map: nil)
                    let line = ActionBudgetLogLine(sample: sample, records: records, sampling: sampling,
                                                   frames: { resolver.frames(for: $0.addresses) })
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
        let (unbatched, dropped) = await mainWork.apply(.automation, owner: "ActionBudgetReporter.counts") { [monitor] in
            (monitor.takeUnbatched(), monitor.droppedRunCount)
        }
        await ledger.note(unbatched)
        return await ledger.snapshot(dropped: Int(clamping: dropped))
    }

    /// `debug.action_budget`: the report's counters, the newest runs from the monitor's ring (with their
    /// real ids: a Debug method), and `registry`'s pipeline counts: handlers bound with an effect and the
    /// untyped rest, and the runs of waiting effects by action and reason (what still shows nothing first).
    ///
    /// - Parameter registry: The app's registry.
    /// - Returns: The control method.
    public func method(registry: ActionRegistry) -> ControlMethod {
        .async("debug.action_budget") { [self] call in
            let limit = call.params["limit"]?.intValue ?? 64
            let (recent, over, droppedSamples, pipeline) = await mainWork.apply(.automation, owner: "debug.action_budget") {
                [monitor, weak registry] in
                (monitor.recent(limit), monitor.overBudgetCount, monitor.droppedSampleCount, registry.map(Self.pipeline) ?? .null)
            }
            guard case .object(var members) = await counts().json else { return .null }
            members["pipeline"] = pipeline
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

    /// The registry's pipeline counts as JSON.
    @MainActor
    private static func pipeline(_ registry: ActionRegistry) -> JSONValue {
        .object([
            "effect_bound": JSONValue(registry.effectBoundCount),
            "untyped_bound": JSONValue(registry.legacyBoundCount),
            "waiting_runs": .object(Dictionary(registry.waitingRuns.map { id, reasons in
                (id.rawValue, JSONValue.object(Dictionary(reasons.map { ($0.key.rawValue, JSONValue($0.value)) }, uniquingKeysWith: { first, _ in first })))
            }, uniquingKeysWith: { first, _ in first })),
        ])
    }
}
