/// A repository-wide working-tree diff summary.
public struct DiffSummary: Sendable, Codable, Equatable {
    /// The resolved baseline used by the comparison.
    public let baseInfo: DiffBaseInfo
    /// Aggregate file and line counts.
    public let totals: DiffTotals
    /// Changed files in Git's deterministic path order, followed by untracked paths.
    public let files: [DiffFileSummary]
    /// The number of files withheld from ``files``; currently always zero.
    public let truncatedFileCount: Int

    /// Creates a repository diff summary.
    /// - Parameters:
    ///   - baseInfo: The concrete resolved baseline.
    ///   - totals: Aggregate file and line counts.
    ///   - files: Per-file summary metadata.
    ///   - truncatedFileCount: The number of file entries withheld from `files`.
    public init(
        baseInfo: DiffBaseInfo,
        totals: DiffTotals,
        files: [DiffFileSummary],
        truncatedFileCount: Int
    ) {
        self.baseInfo = baseInfo
        self.totals = totals
        self.files = files
        self.truncatedFileCount = truncatedFileCount
    }
}
