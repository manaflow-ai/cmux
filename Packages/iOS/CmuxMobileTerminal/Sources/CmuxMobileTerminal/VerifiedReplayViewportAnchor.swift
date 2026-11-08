/// A content-relative viewport position captured before a verified replay.
public struct VerifiedReplayViewportAnchor: Equatable, Sendable {
    /// The number of rows between the viewport top and the content bottom.
    public let topRowDistanceFromBottom: UInt64
    /// The total row-space size when the viewport was captured.
    public let totalRows: UInt64
    /// Cumulative rows the consumer had pushed into local scrollback when the
    /// viewport was captured. Restores diff this against the live counter to
    /// recover eviction the scrollback cap hides from ``totalRows``.
    public let rowsPushedAtCapture: UInt64

    /// Creates a viewport anchor from content-relative row-space values.
    ///
    /// - Parameters:
    ///   - topRowDistanceFromBottom: Rows from the viewport top to content bottom.
    ///   - totalRows: Total row-space size at capture time.
    ///   - rowsPushedAtCapture: Cumulative local scrollback pushes at capture time.
    public init(
        topRowDistanceFromBottom: UInt64,
        totalRows: UInt64,
        rowsPushedAtCapture: UInt64 = 0
    ) {
        self.topRowDistanceFromBottom = topRowDistanceFromBottom
        self.totalRows = totalRows
        self.rowsPushedAtCapture = rowsPushedAtCapture
    }

    /// Creates an anchor when a scrollbar snapshot is above the content bottom.
    ///
    /// `len` is excluded from the anchor so visible-row flicker cannot
    /// accumulate across replays.
    ///
    /// - Parameters:
    ///   - scrollbarTotal: Total row-space size at capture time.
    ///   - offset: Top visible row at capture time.
    ///   - len: Number of visible rows at capture time.
    ///   - rowsPushedAtCapture: Cumulative local scrollback pushes at capture time.
    /// - Returns: An anchor above bottom, or `nil` at or below bottom.
    public init?(
        scrollbarTotal: UInt64,
        offset: UInt64,
        len: UInt64,
        rowsPushedAtCapture: UInt64 = 0
    ) {
        guard offset < scrollbarTotal else { return nil }
        let rowsAfterOffset = scrollbarTotal - offset
        guard len < rowsAfterOffset else { return nil }
        self.init(
            topRowDistanceFromBottom: rowsAfterOffset,
            totalRows: scrollbarTotal,
            rowsPushedAtCapture: rowsPushedAtCapture
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
        targetTopRow(
            postReplayTotalRows: postReplayTotalRows,
            postReplayVisibleRows: postReplayVisibleRows,
            rowsPushedSinceCapture: 0
        )
    }

    /// Computes the post-replay top row that preserves the captured content,
    /// including content the scrollback cap evicted while rows were pushed.
    ///
    /// Every row pushed through the grid either grows the row space (below the
    /// cap) or evicts a retained row from the top (at the cap), so the total
    /// drift between capture and restore is `max(growth, rowsPushed)`. A row
    /// space that shrank below the captured total was rebuilt (hydration), and
    /// local push accounting cannot place content in it; that case keeps the
    /// growth-canceled distance-from-bottom fallback.
    ///
    /// - Parameters:
    ///   - postReplayTotalRows: Total row-space size after replay.
    ///   - postReplayVisibleRows: Number of rows visible after replay.
    ///   - rowsPushedSinceCapture: Rows pushed into local scrollback between
    ///     this anchor's capture and the restore.
    /// - Returns: The clamped target top row, or `nil` for natural bottom follow.
    public func targetTopRow(
        postReplayTotalRows: UInt64,
        postReplayVisibleRows: UInt64,
        rowsPushedSinceCapture: UInt64
    ) -> UInt64? {
        guard topRowDistanceFromBottom > 0 else { return nil }

        let maximumTopRow = postReplayTotalRows > postReplayVisibleRows
            ? postReplayTotalRows - postReplayVisibleRows
            : 0
        let drift: UInt64
        if postReplayTotalRows >= totalRows {
            let growth = postReplayTotalRows - totalRows
            drift = max(growth, rowsPushedSinceCapture)
        } else {
            drift = 0
        }

        guard topRowDistanceFromBottom <= postReplayTotalRows else { return 0 }
        let topRowBeforeDrift = postReplayTotalRows - topRowDistanceFromBottom
        guard drift <= topRowBeforeDrift else { return 0 }
        let idealTop = topRowBeforeDrift - drift
        return min(idealTop, maximumTopRow)
    }
}
