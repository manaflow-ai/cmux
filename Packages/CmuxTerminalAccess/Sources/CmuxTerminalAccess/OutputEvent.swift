import Foundation

/// One event emitted on an active output subscription.
///
/// `seq` is a monotonic per-subscriber identifier (D6 — event-level,
/// not byte-level). Per D6, a ring overflow drops oldest events and
/// the client observes a JUMP in `seq` values rather than a separate
/// gap event; Phase 2 emits at most a single synthetic SSE comment on
/// resume below the oldest seq.
///
/// The ``gap(seq:)`` case is retained for exhaustive switching in
/// downstream code, but the Phase 2 SSE writer does not emit it.
public enum OutputEvent: Sendable {
    /// Raw PTY byte increment with its per-subscriber `seq`.
    case rawBytes(Data, seq: UInt64)
    /// Full ``CellGrid`` snapshot with its per-subscriber `seq`.
    case cellsSnapshot(CellGrid, seq: UInt64)
    /// Reserved synthetic gap marker (per D6, normally unused — clients
    /// observe a JUMP in `seq` instead).
    case gap(seq: UInt64)
}
