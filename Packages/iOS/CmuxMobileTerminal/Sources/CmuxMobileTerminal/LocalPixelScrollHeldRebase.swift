#if canImport(UIKit)

/// Content-true rebase for a gesture's held pixel-scroll position after the
/// row space changed underneath it.
///
/// A held position is an offset from the top of local scrollback. While the
/// scrollback is below its cap that offset is content-stable, but once the cap
/// is reached every pushed row evicts retained rows from the top and the same
/// offset names newer content. `row_space_revision` changes on eviction, so a
/// revision-mismatched held position must not be re-applied verbatim; falling
/// back to the live viewport is also wrong mid-gesture, because a verified
/// replay may have just reset the live viewport to the bottom.
///
/// This decision is pure so the rebase arithmetic is unit-testable without a
/// Ghostty surface.
extension GhosttySurfaceView.LocalPixelScrollState {
    /// Rebases a revision-mismatched held position onto the current row space.
    ///
    /// - Parameters:
    ///   - heldPositionPx: The held content-space position (offset from
    ///     scrollback top, in device pixels).
    ///   - heldTotal: The row-space total when the held position was applied.
    ///   - heldRowsPushed: Cumulative local scrollback pushes when the held
    ///     position was applied.
    ///   - scrollbarTotal: The live row-space total.
    ///   - rowsPushedNow: Cumulative local scrollback pushes now.
    ///   - cellHeightPx: Cell height in device pixels.
    /// - Returns: The content-true position in the current row space, or `nil`
    ///   when the row spaces cannot be reconciled (rebuilt or shrunk space,
    ///   incoherent counters) and the live viewport must be trusted instead.
    static func rebasedHeldPositionPx(
        heldPositionPx: Double,
        heldTotal: UInt64,
        heldRowsPushed: UInt64,
        scrollbarTotal: UInt64,
        rowsPushedNow: UInt64,
        cellHeightPx: Double
    ) -> Double? {
        nil
    }
}
#endif
