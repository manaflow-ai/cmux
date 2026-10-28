public import CmuxNextActions
public import CmuxNextMetrics

/// Folds every action run into a latency histogram per report id and entrypoint, off the main
/// actor: the Release side of the per-action budget. ``ActionBudgetReporter`` feeds it the
/// monitor's batches; the opt-in nightly report reads ``snapshot(dropped:)``.
///
/// The same fold records the actions' field histograms (p09-observability task 056; Chrome reads latency and
/// smoothness per interaction the same way, cc/metrics/event_latency_tracker.cc and
/// cc/metrics/frame_sequence_tracker.cc): `action.commit.<entrypoint>` for every committed run, `action.cmd_t`,
/// `action.cmd_n` and `action.cmd_w` for the key runs of New Tab, New Window and Close Tab (``command(for:)``).
/// None of it adds work to the action's turn: the runs reach the ledger after the commit they are timed to. Their
/// `action.missed_frames.<command>` is recorded on main where the frames after the commit are counted
/// (``ActionCommitWindows``), not here.
public actor ActionBudgetLedger {
    /// The histogram's bucket edges in milliseconds (fixed, so reports from every build and day
    /// add up, and p95 / p99 come out of the counts): a run counts in the first edge it does not
    /// exceed; a run over 250 ms counts in the last bucket.
    public static let bucketEdgesMilliseconds: [Double] = [2, 4, 6, 8, 10, 12, 16, 24, 33, 50, 100, 250]

    /// Rows kept; the catalog is finite (about 1,200 actions times 8 entrypoints at most) and
    /// uncataloged ids fold into two report ids, so this bound is never reached in practice.
    public static let maxRows = 4_096

    private struct Key: Hashable {
        let id: String
        let entrypoint: ActionEntrypoint
    }

    /// The budget, in milliseconds.
    public let budgetMilliseconds: Double
    private let naming: ActionReportNaming
    private let metrics: Metrics
    private var rows: [Key: ActionBudgetRow] = [:]
    private var total = 0
    private var excluded = 0
    private var over = 0

    /// - Parameters:
    ///   - budgetMilliseconds: The monitor's budget.
    ///   - naming: Maps an action to its report id (catalog id, `custom` or `extension`).
    ///   - metrics: Where the field histograms go (the app's metrics file by default; tests pass their own).
    public init(budgetMilliseconds: Double, naming: ActionReportNaming, metrics: Metrics = Metrics()) {
        self.budgetMilliseconds = budgetMilliseconds
        self.naming = naming
        self.metrics = metrics
    }

    /// The timed command whose `action.cmd_*` and `action.missed_frames.*` histograms `id`'s key runs go to: the
    /// catalog's New Tab (Cmd-T), New Window (`cmd_n`, the catalog's "Cmd-N, a new window"; Shift-Cmd-N in cmux)
    /// and Close Tab (Cmd-W). Keyed by action, so a rebound shortcut still counts as its action.
    public nonisolated static func command(for id: ActionID) -> HistogramID.Command? {
        HistogramID.Command.allCases.first { actionID(of: $0) == id }
    }

    /// The catalog action whose key runs `command`'s histograms time (the inverse of ``command(for:)``).
    public nonisolated static func actionID(of command: HistogramID.Command) -> ActionID {
        switch command {
        case .cmdT: "newTab.default"
        case .cmdN: "newWindow"
        case .cmdW: "closeTab"
        }
    }

    /// Folds `runs` in.
    public func note(_ runs: [ActionTimingSample]) {
        for run in runs { note(run) }
    }

    private func note(_ run: ActionTimingSample) {
        total += 1
        guard run.outcome == .committed else {
            excluded += 1
            return
        }
        recordFieldHistograms(run)
        let ms = run.milliseconds
        if ms > budgetMilliseconds { over += 1 }
        let edges = Self.bucketEdgesMilliseconds
        let bucket = edges.firstIndex { ms <= $0 } ?? edges.count
        let key = Key(id: naming.reportID(for: run.id), entrypoint: run.entrypoint)
        if var row = rows[key] {
            row.count += 1
            row.buckets.modify(checked: bucket) { $0 += 1 }
            row.maxMilliseconds = max(row.maxMilliseconds, ms)
            rows[key] = row
        } else if rows.count < Self.maxRows {
            var buckets = [Int](repeating: 0, count: edges.count + 1)
            buckets.modify(checked: bucket) { $0 = 1 }
            rows[key] = ActionBudgetRow(id: key.id, entrypoint: run.entrypoint.rawValue, count: 1, buckets: buckets, maxMilliseconds: ms)
        }
    }

    /// `action.commit.<entrypoint>` (start to commit) and, for a timed command's key run, `action.cmd_*` from the
    /// key event to the commit.
    private func recordFieldHistograms(_ run: ActionTimingSample) {
        let microseconds = Int64(clamping: run.nanos / 1_000)
        metrics.record(.actionCommit(HistogramID.Entrypoint(run.entrypoint)), microseconds)
        guard run.entrypoint == .key, let command = Self.command(for: run.id) else { return }
        let fromInput = run.inputToCommitMilliseconds.flatMap { Int64(exactly: ($0 * 1_000).rounded()) } ?? microseconds
        metrics.record(.actionCommand(command), fromInput)
    }

    /// The counters now, the most frequent row first (then the slowest, then by id).
    ///
    /// - Parameter dropped: Runs the monitor could not hand over (``ActionBudgetMonitor/droppedRunCount``).
    public func snapshot(dropped: Int) -> ActionBudgetCounts {
        let sorted = rows.values.sorted {
            ($0.count, $0.maxMilliseconds, $1.id, $1.entrypoint) > ($1.count, $1.maxMilliseconds, $0.id, $0.entrypoint)
        }
        return ActionBudgetCounts(budgetMilliseconds: budgetMilliseconds, bucketEdgesMilliseconds: Self.bucketEdgesMilliseconds,
                                  runsTotal: total, runsExcluded: excluded, runsDropped: dropped, overBudgetTotal: over, rows: sorted)
    }
}

extension HistogramID.Entrypoint {
    /// The `action.commit` histogram of runs from `entrypoint` (the same cases, by name).
    init(_ entrypoint: ActionEntrypoint) {
        switch entrypoint {
        case .key: self = .key
        case .pointer: self = .pointer
        case .unattributed: self = .unattributed
        case .cli: self = .cli
        case .mcp: self = .mcp
        case .script: self = .script
        case .remote: self = .remote
        case .page: self = .page
        }
    }
}
