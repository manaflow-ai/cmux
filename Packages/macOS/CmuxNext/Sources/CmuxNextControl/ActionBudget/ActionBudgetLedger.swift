public import CmuxNextActions

/// Folds every action run into a latency histogram per report id and entrypoint, off the main
/// actor: the Release side of the per-action budget. ``ActionBudgetReporter`` feeds it the
/// monitor's batches; the opt-in nightly report reads ``snapshot(dropped:)``.
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
    private var rows: [Key: ActionBudgetRow] = [:]
    private var total = 0
    private var excluded = 0
    private var over = 0

    /// - Parameters:
    ///   - budgetMilliseconds: The monitor's budget.
    ///   - naming: Maps an action to its report id (catalog id, `custom` or `extension`).
    public init(budgetMilliseconds: Double, naming: ActionReportNaming) {
        self.budgetMilliseconds = budgetMilliseconds
        self.naming = naming
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
