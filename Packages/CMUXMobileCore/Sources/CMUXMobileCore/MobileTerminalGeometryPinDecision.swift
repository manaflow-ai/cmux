import Foundation

/// Compute the next authoritative grid pin given the current pin and an
/// incoming frame's grid.
///
/// The phone's pinned grid (`effectiveGrid` on the surface) has exactly one
/// authoritative source on a render-grid host: the ordered render-grid frame
/// stream from the Mac. Every frame and the cold-attach replay carry the Mac's
/// live `columns`/`rows` plus the geometry generation that ordered them, and
/// the viewport RPC reply carries the same generation. This collapses what used
/// to be two sources of truth for one fact (the frame grid vs. the
/// viewport-RPC reply) into one ordered decision, so the pin converges on
/// initial attach and on any Mac-side resize without a phone-initiated
/// round-trip.
///
/// Live frames arrive over an ordered `AsyncStream`, so steady-state ordering
/// is already guaranteed by the stream itself. The generation is the order key
/// that lets the out-of-band viewport reply be merged safely: an older
/// generation can never overwrite a newer grid, and a reply for a phone-side
/// resize the Mac pushed no frame for still advances the pin. A frame at the
/// same generation that reports a different grid still updates, because the
/// grid is the fact being tracked.
///
/// - Parameters:
///   - current: The pin currently applied, or `nil` if none has been applied
///     yet.
///   - incomingColumns: The columns carried by the incoming frame.
///   - incomingRows: The rows carried by the incoming frame.
///   - incomingSeq: The geometry generation carried by the incoming frame.
/// - Returns: The pin to apply, or `nil` if the incoming frame must be ignored
///   (older generation, or no change). `nil` means "leave the current pin
///   untouched"; the caller must not re-apply geometry.
public func mobileTerminalNextGridPin(
    current: MobileTerminalGridPin?,
    incomingColumns: Int,
    incomingRows: Int,
    incomingSeq: UInt64
) -> MobileTerminalGridPin? {
    // A frame with a non-positive grid carries no usable geometry (e.g. a
    // surface that has not measured yet). Never let it clear the pin.
    guard incomingColumns > 0, incomingRows > 0 else { return nil }

    guard let current else {
        // First authoritative grid wins unconditionally; the initial pin is
        // whatever the first frame reports, so the phone never renders at a
        // guessed/stale local size before the Mac grid is known.
        return MobileTerminalGridPin(
            columns: incomingColumns,
            rows: incomingRows,
            geometrySeq: incomingSeq
        )
    }

    // Reject a strictly older generation: a cold-attach replay can overlap the
    // first live frames and carry an older generation than one already applied.
    // Applying it would let a stale grid win.
    if incomingSeq < current.geometrySeq {
        return nil
    }

    // Same-or-newer generation: only move the pin when the grid actually
    // differs, so an unchanged grid does not churn a geometry resync. The
    // generation high-water mark tracks the newest observed frame.
    if incomingColumns == current.columns,
       incomingRows == current.rows {
        return nil
    }

    return MobileTerminalGridPin(
        columns: incomingColumns,
        rows: incomingRows,
        geometrySeq: max(incomingSeq, current.geometrySeq)
    )
}
