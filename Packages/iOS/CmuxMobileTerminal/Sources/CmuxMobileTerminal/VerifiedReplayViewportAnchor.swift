/// A content-relative viewport position captured before a verified replay.
public struct VerifiedReplayViewportAnchor: Equatable, Sendable {
    /// The number of rows between the viewport bottom and the content bottom.
    public let rowsFromBottom: UInt64
    /// The total row-space size when the viewport was captured.
    public let totalRows: UInt64

    /// Creates a viewport anchor from an authoritative scrollbar snapshot.
    ///
    /// - Parameters:
    ///   - rowsFromBottom: Rows between the viewport bottom and content bottom.
    ///   - totalRows: Total row-space size at capture time.
    public init(rowsFromBottom: UInt64, totalRows: UInt64) {
        self.rowsFromBottom = rowsFromBottom
        self.totalRows = totalRows
    }

    /// Creates an anchor when a scrollbar snapshot is above the content bottom.
    ///
    /// - Parameters:
    ///   - scrollbarTotal: Total row-space size at capture time.
    ///   - offset: Top visible row at capture time.
    ///   - len: Number of visible rows at capture time.
    public init?(scrollbarTotal: UInt64, offset: UInt64, len: UInt64) {
        guard offset < scrollbarTotal else { return nil }
        let rowsAfterOffset = scrollbarTotal - offset
        guard len < rowsAfterOffset else { return nil }
        self.init(
            rowsFromBottom: rowsAfterOffset - len,
            totalRows: scrollbarTotal
        )
    }

    /// Computes the post-replay top row that preserves the captured content.
    ///
    /// Growth in the row space is treated as replay drift and canceled out so
    /// the same absolute content remains visible. If a scrollback cap hides
    /// that growth, the calculation naturally preserves distance from bottom.
    ///
    /// - Parameters:
    ///   - postReplayTotalRows: Total row-space size after replay.
    ///   - postReplayVisibleRows: Number of rows visible after replay.
    /// - Returns: The clamped target top row, or `nil` for natural bottom follow.
    public func targetTopRow(
        postReplayTotalRows: UInt64,
        postReplayVisibleRows: UInt64
    ) -> UInt64? {
        guard rowsFromBottom > 0 else { return nil }

        let maximumTopRow = postReplayTotalRows > postReplayVisibleRows
            ? postReplayTotalRows - postReplayVisibleRows
            : 0
        let drift = postReplayTotalRows > totalRows
            ? postReplayTotalRows - totalRows
            : 0

        guard rowsFromBottom <= maximumTopRow else { return 0 }
        let topRowBeforeDrift = maximumTopRow - rowsFromBottom
        guard drift <= topRowBeforeDrift else { return 0 }
        return topRowBeforeDrift - drift
    }
}
