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
    /// Resolves the content-space base position for one gesture batch.
    ///
    /// Mid-gesture the held position is the authority: a verified replay may
    /// have reset the live viewport to the bottom between batches, and
    /// deriving from it would make the reset hijack the gesture. The hold has
    /// two anchoring modes: a hold docked at the tail is BOTTOM-anchored and
    /// targets the LIVE tail, so output appended between batches cannot leave
    /// the viewport a row behind the bottom (the pin-to-bottom contract of
    /// messaging apps); an undocked hold is CONTENT-anchored and keeps the
    /// same rows visible, rebased content-true across a row-space revision
    /// change. Only an unreconcilable space falls back to the live viewport.
    ///
    /// - Parameters:
    ///   - rebaseFromHeldPosition: Whether a gesture (or its deceleration)
    ///     owns the axis; idle batches always trust the live viewport.
    ///   - held: The last applied position, or `nil` before the first apply.
    ///   - scrollbarOffset: The live viewport top row.
    ///   - scrollbarRevision: The live row-space revision.
    ///   - scrollbarTotal: The live row-space total.
    ///   - rowsPushedNow: Cumulative local scrollback pushes now.
    ///   - remainderPx: The fractional pixel carried between batches.
    ///   - cellHeightPx: Cell height in device pixels.
    ///   - maxPositionPx: The tail position (`(total - len) * cellHeightPx`).
    /// - Returns: The batch's base position in content-space device pixels.
    static func gestureBasePositionPx(
        rebaseFromHeldPosition: Bool,
        held: Held?,
        scrollbarOffset: UInt64,
        scrollbarRevision: UInt64,
        scrollbarTotal: UInt64,
        rowsPushedNow: UInt64,
        remainderPx: Double,
        cellHeightPx: Double,
        maxPositionPx: Double
    ) -> Double {
        if rebaseFromHeldPosition, let held {
            // A docked hold is bottom-anchored: the tail is the tail in every
            // row space, so it needs no revision match and no content rebase.
            // The gesture undocks it by actually moving up (the batch's dock
            // check stores dockedAtTail=false the moment the resolved
            // position leaves the tail).
            if held.dockedAtTail {
                return maxPositionPx
            }
            if held.revision == scrollbarRevision {
                return min(held.positionPx, maxPositionPx)
            }
            if let corrected = rebasedHeldPositionPx(
                heldPositionPx: held.positionPx,
                heldTotal: held.total,
                heldRowsPushed: held.rowsPushed,
                scrollbarTotal: scrollbarTotal,
                rowsPushedNow: rowsPushedNow,
                cellHeightPx: cellHeightPx
            ) {
                return min(corrected, maxPositionPx)
            }
        }
        return min(Double(scrollbarOffset) * cellHeightPx + remainderPx, maxPositionPx)
    }

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
        guard cellHeightPx > 0 else { return nil }
        // A shrunk total means the row space was rebuilt (hydration, reset);
        // held row numbers do not survive it. A rewound counter means the
        // held value belongs to another counting epoch.
        guard scrollbarTotal >= heldTotal else { return nil }
        guard rowsPushedNow >= heldRowsPushed else { return nil }
        let growth = scrollbarTotal - heldTotal
        let pushed = rowsPushedNow - heldRowsPushed
        // Pushes absorbed as growth leave top offsets unchanged; only the
        // remainder evicted retained rows and shifted content upward.
        guard pushed > growth else { return heldPositionPx }
        let evicted = pushed - growth
        return max(0, heldPositionPx - Double(evicted) * cellHeightPx)
    }
}
#endif
