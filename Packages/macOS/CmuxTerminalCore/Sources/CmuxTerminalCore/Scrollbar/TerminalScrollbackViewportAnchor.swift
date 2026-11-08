/// A bottom-relative anchor for restoring a captured terminal viewport.
///
/// The anchor stores the viewport's bottom edge relative to the end of the
/// captured scrollback. It preserves the captured position while those rows
/// retain the same numbering. Bounded scrollback can evict rows, and terminal
/// reflow can renumber them, without exposing a persistent row identity. Use
/// ``topRow(in:)`` to translate the anchor into Ghostty's top-relative
/// `scroll_to_row` coordinate.
public struct TerminalScrollbackViewportAnchor: Equatable, Sendable {
    /// The number of captured rows below the viewport's bottom edge.
    public let rowsBelowViewport: Int

    /// The total number of rows when the viewport position was captured.
    public let capturedTotalRows: Int

    /// Creates an anchor from persisted bottom-relative scrollback geometry.
    ///
    /// Values outside the captured scrollback are clamped so the anchor always
    /// describes a valid bottom edge.
    ///
    /// - Parameters:
    ///   - rowsBelowViewport: Rows between the viewport's bottom edge and the
    ///     end of scrollback.
    ///   - capturedTotalRows: Total scrollback rows at capture time.
    public init(rowsBelowViewport: Int, capturedTotalRows: Int) {
        let normalizedTotalRows = max(0, capturedTotalRows)
        self.rowsBelowViewport = min(normalizedTotalRows, max(0, rowsBelowViewport))
        self.capturedTotalRows = normalizedTotalRows
    }

    /// Captures the semantic viewport position from Ghostty's runtime geometry.
    ///
    /// - Parameter scrollbar: The current top-relative Ghostty scrollbar state.
    /// - Returns: `nil` when the runtime has not established a visible viewport.
    public init?(scrollbar: GhosttyScrollbar) {
        let totalRows = Int(clamping: scrollbar.total)
        let visibleRows = min(totalRows, Int(clamping: scrollbar.len))
        guard visibleRows > 0 else { return nil }
        let lastTopRow = totalRows - visibleRows
        let topRow = min(lastTopRow, Int(clamping: scrollbar.offset))
        self.init(
            rowsBelowViewport: totalRows - topRow - visibleRows,
            capturedTotalRows: totalRows
        )
    }

    /// Resolves the first visible row for Ghostty's current scrollback geometry.
    ///
    /// A live-bottom anchor follows the runtime's current bottom. Historical
    /// anchors wait until their captured bottom edge is addressable, then remain
    /// attached to that output while row numbering is stable. Reflow can
    /// renumber rows without exposing a persistent identity to resolve.
    ///
    /// - Parameter scrollbar: The current top-relative Ghostty scrollbar state.
    /// - Returns: The absolute first visible row, or `nil` before the runtime has
    ///   established a visible viewport.
    public func topRow(in scrollbar: GhosttyScrollbar) -> Int? {
        let currentTotalRows = Int(clamping: scrollbar.total)
        let currentVisibleRows = min(currentTotalRows, Int(clamping: scrollbar.len))
        guard currentVisibleRows > 0 else { return nil }
        let currentLastTopRow = currentTotalRows - currentVisibleRows
        if rowsBelowViewport == 0 {
            return currentLastTopRow
        }
        let capturedViewportBottomRow = capturedTotalRows - rowsBelowViewport
        guard capturedViewportBottomRow <= currentTotalRows else { return nil }
        let unclampedTopRow = max(0, capturedViewportBottomRow - currentVisibleRows)
        return min(currentLastTopRow, unclampedTopRow)
    }
}
