import Foundation

/// The verdict for an incoming render-grid frame's geometry, given the pin
/// currently applied.
///
/// The bytes-vs-pin split is the load-bearing distinction: ``stale`` is the
/// only case whose accompanying VT bytes must be dropped (a frame older than
/// the merged high-water mark is superseded by a newer full frame), while
/// ``keep`` and ``update`` both mean the bytes are current and must be applied.
public enum MobileTerminalGeometryPinVerdict: Equatable, Sendable {
    /// The frame is older than the merged high-water mark. Leave the pin
    /// untouched AND drop the frame's bytes: they would repaint stale content
    /// at the newer grid.
    case stale
    /// The frame matches the current grid and carries nothing newer. Leave the
    /// pin untouched but apply the bytes (they are current).
    case keep
    /// Advance the pin to this value, then apply the bytes. When the grid is
    /// unchanged the pin only records a newer generation (the geometry apply is
    /// a no-op); when the grid differs it also resizes.
    case update(MobileTerminalGridPin)
}

/// Decide how an incoming frame's geometry merges with the current pin.
///
/// The phone's pinned grid (`effectiveGrid` on the surface) has exactly one
/// authoritative source on a render-grid host: the ordered render-grid frame
/// stream from the Mac, merged with the out-of-band viewport RPC reply. Every
/// frame and the cold-attach replay carry the Mac's live `columns`/`rows` plus
/// the geometry generation that ordered them, and the viewport RPC reply
/// carries the same generation. This collapses what used to be two sources of
/// truth for one fact (the frame grid vs. the viewport-RPC reply) into one
/// ordered decision, so the pin converges on initial attach and on any Mac-side
/// resize without a phone-initiated round-trip.
///
/// Live frames arrive over an ordered `AsyncStream`, so steady-state ordering
/// is already guaranteed by the stream itself. The generation is the order key
/// that lets the out-of-band viewport reply be merged safely: a strictly older
/// generation can never overwrite a newer grid, and a reply for a phone-side
/// resize the Mac pushed no frame for still advances the pin. The surface holds
/// the single merged high-water mark across both channels, so it is the only
/// place that can decide whether a frame's bytes are stale.
///
/// On a modern (gen-stamping) host the generation bumps whenever the exported
/// grid changes, so a different grid always carries a strictly newer generation
/// and the high-water mark can never be rewound. On a legacy host that omits
/// `geometry_gen` every frame and reply shares generation 0; ordering then comes
/// only from the `AsyncStream`. An equal-generation different-grid input is a
/// genuine legacy resize and applies (this is the only way a Mac-side grow, and
/// a phone-side resize whose sole acknowledgement is the viewport reply, are
/// learned on a legacy host). The residual is a theoretical out-of-band reply
/// vs. stream race on legacy, which self-heals on the very next frame (any frame
/// re-pins to the live grid); breaking legacy resizes to avoid it would be a far
/// worse regression.
///
/// - Parameters:
///   - current: The pin currently applied, or `nil` if none has been applied
///     yet.
///   - incomingColumns: The columns carried by the incoming frame.
///   - incomingRows: The rows carried by the incoming frame.
///   - incomingSeq: The geometry generation carried by the incoming frame.
/// - Returns: The verdict the caller acts on (drop vs. apply bytes, and whether
///   to advance the pin).
public func mobileTerminalGeometryPinVerdict(
    current: MobileTerminalGridPin?,
    incomingColumns: Int,
    incomingRows: Int,
    incomingSeq: UInt64
) -> MobileTerminalGeometryPinVerdict {
    guard let current else {
        // First authoritative grid wins unconditionally; the initial pin is
        // whatever the first frame reports, so the phone never renders at a
        // guessed/stale local size before the Mac grid is known. A non-positive
        // first grid carries no usable geometry; keep the bytes but do not pin.
        guard incomingColumns > 0, incomingRows > 0 else { return .keep }
        return .update(
            MobileTerminalGridPin(
                columns: incomingColumns,
                rows: incomingRows,
                geometrySeq: incomingSeq
            )
        )
    }

    // A frame with a non-positive grid carries no usable geometry (e.g. a
    // surface that has not measured yet). Never let it clear the pin; its bytes
    // are still current relative to the stream order, so keep them.
    guard incomingColumns > 0, incomingRows > 0 else { return .keep }

    // Strictly older generation: a cold-attach replay can overlap the first
    // live frames and carry an older generation than one already applied (the
    // viewport reply advances the pin out-of-band, so even a same-`stateSeq`
    // replay can be geometry-stale). Drop its bytes too.
    if incomingSeq < current.geometrySeq {
        return .stale
    }

    if incomingColumns == current.columns,
       incomingRows == current.rows {
        // Same grid. Advance the high-water mark on a strictly newer generation
        // so a later delayed frame at an intermediate generation (resize away
        // at gen 11 then back to this grid at gen 12) cannot pass the staleness
        // check. The pin keeps the same grid, so the geometry apply is a no-op.
        guard incomingSeq > current.geometrySeq else { return .keep }
        return .update(
            MobileTerminalGridPin(
                columns: current.columns,
                rows: current.rows,
                geometrySeq: incomingSeq
            )
        )
    }

    // Different grid at a same-or-newer generation: a resize. On a modern host
    // this is always strictly newer (a grid change bumps the generation); the
    // equal-generation case is the legacy `geometry_gen == 0` path, where both a
    // stream frame and a viewport reply must still apply (see the type doc).
    return .update(
        MobileTerminalGridPin(
            columns: incomingColumns,
            rows: incomingRows,
            geometrySeq: max(incomingSeq, current.geometrySeq)
        )
    )
}
