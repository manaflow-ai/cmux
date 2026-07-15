/// The decoded result of `mobile.workspace.diffs.summary`.
public struct MobileDiffSummaryResponse: Codable, Sendable, Equatable {
    /// The resolved comparison baseline.
    public let baseInfo: MobileDiffBaseInfo
    /// Aggregate file and line counts.
    public let totals: MobileDiffTotals
    /// Changed files in host-provided order.
    public let files: [MobileDiffFileSummary]
    /// The number of changed files omitted from ``files``.
    public let truncatedFileCount: Int

    /// Creates a workspace-diff summary response.
    /// - Parameters:
    ///   - baseInfo: The resolved comparison baseline.
    ///   - totals: Aggregate file and line counts.
    ///   - files: Changed files in display order.
    ///   - truncatedFileCount: The number of omitted changed files.
    public init(
        baseInfo: MobileDiffBaseInfo,
        totals: MobileDiffTotals,
        files: [MobileDiffFileSummary],
        truncatedFileCount: Int
    ) {
        self.baseInfo = baseInfo
        self.totals = totals
        self.files = files
        self.truncatedFileCount = truncatedFileCount
    }
}
