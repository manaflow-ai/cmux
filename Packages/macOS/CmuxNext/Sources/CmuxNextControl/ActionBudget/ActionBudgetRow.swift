/// One action and entrypoint's committed runs since launch (``ActionBudgetLedger``): one row of the
/// opt-in nightly latency report (`action_latency`).
public struct ActionBudgetRow: Sendable, Hashable {
    /// The report id (``ActionReportNaming``: the catalog id, `custom` or `extension`).
    public var id: String
    /// Where its runs came from (`ActionEntrypoint.rawValue`: `key`, `pointer`, `cli`, ...).
    public var entrypoint: String
    /// Its committed runs.
    public var count: Int
    /// Runs per perform-to-commit bucket: one per edge of ``ActionBudgetLedger/bucketEdgesMilliseconds``
    /// (a run counts in the first edge it does not exceed), then one for runs over the last edge.
    public var buckets: [Int]
    /// The slowest run's perform-to-commit time, in milliseconds.
    public var maxMilliseconds: Double

    /// - Parameters:
    ///   - id: The report id.
    ///   - entrypoint: Where its runs came from.
    ///   - count: Committed runs.
    ///   - buckets: Runs per bucket.
    ///   - maxMilliseconds: The slowest run.
    public init(id: String, entrypoint: String, count: Int, buckets: [Int], maxMilliseconds: Double) {
        self.id = id
        self.entrypoint = entrypoint
        self.count = count
        self.buckets = buckets
        self.maxMilliseconds = maxMilliseconds
    }
}
