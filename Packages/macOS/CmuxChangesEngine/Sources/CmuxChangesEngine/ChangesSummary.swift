/// Contains repository-wide changes metadata and per-file summaries.
public struct ChangesSummary: Sendable, Equatable {
    /// The resolved baseline used by the comparison.
    public let baseInfo: ChangesBaseInfo
    /// Aggregate counts across every changed file.
    public let totals: ChangesTotals
    /// The returned file summaries, sorted by new-side path.
    public let files: [ChangesFile]
    /// The number of changed files omitted by the summary response cap.
    public let truncatedFileCount: Int

    /// Creates a repository changes summary.
    /// - Parameters:
    ///   - baseInfo: The resolved baseline metadata.
    ///   - totals: Aggregate file and line counts.
    ///   - files: The returned file summaries.
    ///   - truncatedFileCount: The count omitted by the response cap.
    public init(
        baseInfo: ChangesBaseInfo,
        totals: ChangesTotals,
        files: [ChangesFile],
        truncatedFileCount: Int
    ) {
        self.baseInfo = baseInfo
        self.totals = totals
        self.files = files
        self.truncatedFileCount = truncatedFileCount
    }
}
