/// Pure continuation inputs for a progressively loaded file diff.
public struct FileDiffContinuation: Sendable, Equatable {
    /// Default line budget used by legacy and initial requests.
    public static let defaultLineBudget = 6_000
    /// Largest line budget the mobile client requests over the bounded transport.
    public static let maximumLineBudget = 96_000

    /// Line budget that produced the current document.
    public let lineBudget: Int
    /// Number of raw diff lines present in the current document.
    public let shownLineCount: Int
    /// Unclamped number of raw diff lines present in the current document.
    public let loadedRawLineCount: Int
    /// Number of raw lines in the full diff, when reported by the host.
    public let totalLineCount: Int?
    /// Whether the host reports that the current response is truncated.
    public let isTruncated: Bool
    /// Whether a larger request stopped increasing the transported window.
    public let reachedTransportCeiling: Bool

    /// Creates continuation state for a loaded document.
    ///
    /// - Parameters:
    ///   - lineBudget: Line budget that produced `document`.
    ///   - document: Current parsed diff document.
    ///   - reachedTransportCeiling: Whether a larger request returned no more raw lines.
    public init(
        lineBudget: Int,
        document: FileDiffDocument,
        reachedTransportCeiling: Bool = false
    ) {
        self.lineBudget = min(
            max(lineBudget, Self.defaultLineBudget),
            Self.maximumLineBudget
        )
        totalLineCount = document.totalLineCount.map { max(0, $0) }
        isTruncated = document.truncated
        let loadedRawLineCount = max(0, document.loadedLineCount)
        self.loadedRawLineCount = loadedRawLineCount
        self.reachedTransportCeiling = reachedTransportCeiling
        shownLineCount = document.totalLineCount.map {
            min(loadedRawLineCount, max(0, $0))
        } ?? loadedRawLineCount
    }

    /// Whether the continuation footer should remain visible.
    public var shouldShowFooter: Bool {
        isTruncated
    }

    /// Whether another bounded request can grow the transported diff window.
    public var canShowMore: Bool {
        isTruncated
            && !reachedTransportCeiling
            && nextLineBudget > lineBudget
    }

    /// Four-times-larger request budget, saturated at the mobile transport ceiling.
    public var nextLineBudget: Int {
        let (grown, overflowed) = lineBudget.multipliedReportingOverflow(by: 4)
        guard !overflowed else { return Self.maximumLineBudget }
        return min(grown, Self.maximumLineBudget)
    }

    /// Detects a transport ceiling after a strictly larger request.
    /// - Parameters:
    ///   - document: Document returned by the larger request.
    ///   - requestedLineBudget: Line budget used for that request.
    /// - Returns: `true` when the raw transported window did not grow.
    public func reachedTransportCeiling(
        afterLoading document: FileDiffDocument,
        requestedLineBudget: Int
    ) -> Bool {
        requestedLineBudget > lineBudget
            && max(0, document.loadedLineCount) <= loadedRawLineCount
    }
}
