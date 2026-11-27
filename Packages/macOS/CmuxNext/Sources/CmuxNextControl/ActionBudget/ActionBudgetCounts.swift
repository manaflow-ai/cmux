public import CmuxNextSettings

/// The per-action budget counters at one moment (``ActionBudgetReporter/counts()``): the fields the
/// opt-in nightly hang and latency report carries (PL-telemetry owns the report).
///
/// Fields: `action_budget_ms`, `action_latency_bucket_edges_ms`, `action_runs_total` (runs
/// counted), `action_runs_excluded` (missed commits and nested-loop runs: not the run's work, kept
/// out of the histogram), `action_runs_dropped` (runs the reporter never got: it fell behind),
/// `action_over_budget_total`, and `action_latency` (per report id and entrypoint: `id`,
/// `entrypoint`, `count`, `buckets` (one per edge, then over), `max_ms`; the most frequent first).
/// Report ids only (``ActionReportNaming``): no user text.
public struct ActionBudgetCounts: Sendable, Hashable {
    /// The budget, in milliseconds.
    public var budgetMilliseconds: Double
    /// The histogram's bucket edges, in milliseconds.
    public var bucketEdgesMilliseconds: [Double]
    /// Runs counted (committed, missed and nested).
    public var runsTotal: Int
    /// Missed-commit and nested-loop runs (outside the histogram).
    public var runsExcluded: Int
    /// Runs the reporter never got.
    public var runsDropped: Int
    /// Committed runs over budget.
    public var overBudgetTotal: Int
    /// Per report id and entrypoint, the most frequent first.
    public var rows: [ActionBudgetRow]

    /// - Parameters:
    ///   - budgetMilliseconds: The budget.
    ///   - bucketEdgesMilliseconds: The bucket edges.
    ///   - runsTotal: Runs counted.
    ///   - runsExcluded: Runs outside the histogram.
    ///   - runsDropped: Runs never received.
    ///   - overBudgetTotal: Committed runs over budget.
    ///   - rows: Per report id and entrypoint.
    public init(budgetMilliseconds: Double, bucketEdgesMilliseconds: [Double], runsTotal: Int, runsExcluded: Int,
                runsDropped: Int, overBudgetTotal: Int, rows: [ActionBudgetRow]) {
        self.budgetMilliseconds = budgetMilliseconds
        self.bucketEdgesMilliseconds = bucketEdgesMilliseconds
        self.runsTotal = runsTotal
        self.runsExcluded = runsExcluded
        self.runsDropped = runsDropped
        self.overBudgetTotal = overBudgetTotal
        self.rows = rows
    }

    /// The report's fields as JSON (the field names above).
    public var json: JSONValue {
        .object([
            "action_budget_ms": .number(budgetMilliseconds),
            "action_latency_bucket_edges_ms": .array(bucketEdgesMilliseconds.map(JSONValue.number)),
            "action_runs_total": JSONValue(runsTotal),
            "action_runs_excluded": JSONValue(runsExcluded),
            "action_runs_dropped": JSONValue(runsDropped),
            "action_over_budget_total": JSONValue(overBudgetTotal),
            "action_latency": .array(rows.map { row in
                .object([
                    "id": .string(row.id),
                    "entrypoint": .string(row.entrypoint),
                    "count": JSONValue(row.count),
                    "buckets": .array(row.buckets.map { JSONValue($0) }),
                    "max_ms": .number(row.maxMilliseconds),
                ])
            }),
        ])
    }
}
