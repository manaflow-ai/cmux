/// Pure continuation inputs for a progressively loaded file diff.
public struct FileDiffContinuation: Sendable, Equatable {
    /// Default line budget used by legacy and initial requests.
    public static let defaultLineBudget = 6_000
    /// Largest line budget accepted by the host response guard.
    public static let maximumLineBudget = 1_000_000

    /// Line budget that produced the current document.
    public let lineBudget: Int
    /// Number of raw diff lines present in the current document.
    public let shownLineCount: Int
    /// Number of raw lines in the full diff, when reported by the host.
    public let totalLineCount: Int?
    /// Whether the host reports that the current response is truncated.
    public let isTruncated: Bool

    /// Creates continuation state for a loaded document.
    ///
    /// - Parameters:
    ///   - lineBudget: Line budget that produced `document`.
    ///   - document: Current parsed diff document.
    public init(lineBudget: Int, document: FileDiffDocument) {
        self.lineBudget = min(
            max(lineBudget, Self.defaultLineBudget),
            Self.maximumLineBudget
        )
        totalLineCount = document.totalLineCount.map { max(0, $0) }
        isTruncated = document.truncated
        shownLineCount = document.totalLineCount.map {
            min(max(0, document.loadedLineCount), max(0, $0))
        } ?? max(0, document.loadedLineCount)
    }

    /// Whether the continuation footer should remain visible.
    public var shouldShowFooter: Bool {
        isTruncated
    }

    /// Whether the host supplied enough metadata to request a larger window.
    public var canShowMore: Bool {
        isTruncated && totalLineCount != nil
    }

    /// Four-times-larger request budget, saturated at the host response guard.
    public var nextLineBudget: Int {
        let (grown, overflowed) = lineBudget.multipliedReportingOverflow(by: 4)
        guard !overflowed else { return Self.maximumLineBudget }
        return min(grown, Self.maximumLineBudget)
    }
}
