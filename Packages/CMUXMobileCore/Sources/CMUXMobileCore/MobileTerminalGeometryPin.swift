import Foundation

/// The authoritative terminal grid (in character cells) the phone should pin
/// its local libghostty surface to, paired with the geometry sequence that
/// produced it.
///
/// Unlike ``TerminalGridSize`` (which also carries pixel extents measured on a
/// specific device), this is purely the cell grid the Mac is rendering at. It
/// is the value carried on every render-grid frame (``columns``/``rows``) and
/// returned by the viewport RPC, so the phone can letterbox its own render to
/// match the shared grid without re-measuring.
/// One chunk yielded by the phone's terminal output stream.
///
/// Bytes and the authoritative grid that produced them travel together so the
/// surface can pin its geometry from the *same* frame whose VT bytes it
/// applies, keeping content and grid atomic. ``grid`` is `nil` only for the
/// raw-byte compatibility fallback (an older Mac host with no render-grid
/// frame), which carries no authoritative grid; such a chunk leaves the pin
/// untouched.
public struct MobileTerminalOutputChunk: Equatable, Sendable {
    /// The VT bytes to feed to the local libghostty surface.
    public var bytes: Data
    /// The authoritative Mac grid carried by the frame these bytes came from,
    /// or `nil` for a raw-byte fallback chunk with no grid.
    public var grid: MobileTerminalGridPin?

    public init(bytes: Data, grid: MobileTerminalGridPin? = nil) {
        self.bytes = bytes
        self.grid = grid
    }
}

public struct MobileTerminalGridPin: Equatable, Hashable, Sendable {
    /// The number of character columns the Mac is rendering at.
    public var columns: Int
    /// The number of character rows the Mac is rendering at.
    public var rows: Int
    /// The frame sequence (the byte `stateSeq`) that carried this grid. Used as
    /// a defensive backstop so a cold-attach replay that overlaps the first
    /// live frames cannot apply a strictly older frame on top of a newer one.
    /// It is NOT a dense geometry counter: `stateSeq` does not advance on a pure
    /// resize, so two different grids can legitimately share a sequence. The
    /// live ordering guarantee comes from the ordered frame `AsyncStream`, not
    /// from this value.
    public var geometrySeq: UInt64

    public init(columns: Int, rows: Int, geometrySeq: UInt64) {
        self.columns = columns
        self.rows = rows
        self.geometrySeq = geometrySeq
    }
}

/// Pure decision for the phone's authoritative grid pin.
///
/// The phone's pinned grid (`effectiveGrid` on the surface) has exactly one
/// authoritative source on a render-grid host: the ordered render-grid frame
/// stream from the Mac. Every frame and the cold-attach replay carry the Mac's
/// live `columns`/`rows` plus the byte `stateSeq` that ordered them. This
/// collapses what used to be two sources of truth for one fact (the frame grid
/// vs. the viewport-RPC reply) into the single ordered stream, so the pin
/// converges on initial attach and on any Mac-side resize without a
/// phone-initiated round-trip.
///
/// Live frames arrive over an ordered `AsyncStream`, so steady-state ordering
/// is already guaranteed by the stream itself, not by this function. The
/// sequence is only a defensive backstop: it rejects a strictly older frame so
/// a cold-attach replay that overlaps the first live frames cannot apply on top
/// of a newer one. A frame at the same sequence that reports a different grid
/// (a resize whose byte sequence did not advance) still updates, because the
/// grid is the fact being tracked, not the byte offset.
public enum MobileTerminalGeometryPinDecision {
    /// Compute the next pin given the current pin and an incoming frame's grid.
    ///
    /// - Parameters:
    ///   - current: The pin currently applied, or `nil` if none has been
    ///     applied yet.
    ///   - incomingColumns: The columns carried by the incoming frame.
    ///   - incomingRows: The rows carried by the incoming frame.
    ///   - incomingSeq: The byte/state sequence carried by the incoming frame.
    /// - Returns: The pin to apply, or `nil` if the incoming frame must be
    ///   ignored (stale sequence, or no change). `nil` means "leave the current
    ///   pin untouched"; the caller must not re-apply geometry.
    public static func nextPin(
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

        // Reject a strictly older frame: a cold-attach replay can overlap the
        // first live frames and carry a smaller sequence than one already
        // applied. Applying it would let a stale grid win.
        if incomingSeq < current.geometrySeq {
            return nil
        }

        // Same-or-newer sequence: only move the pin when the grid actually
        // differs, so an unchanged grid does not churn a geometry resync. The
        // sequence high-water mark tracks the newest observed frame.
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
}
