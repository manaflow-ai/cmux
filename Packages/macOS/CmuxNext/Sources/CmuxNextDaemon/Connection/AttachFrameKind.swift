import Foundation

/// What a binary attach frame's payload holds (`attach-frames-v1`,
/// plans/cmux-next/app-daemon-connection-DESIGN.md section 3.2).
enum AttachFrameKind: UInt8, Sendable {
    /// Raw PTY bytes; the header's offset is the first byte's.
    case output = 1
    /// In-band resize marker: JSON meta (cols, rows, optional history check).
    case grid = 2
    /// One JSON event object.
    case event = 3
    /// A READY snapshot: `meta_len u32`, JSON meta, raw data.
    case snapshot = 4
    /// A history or images chunk of the last READY, same shape.
    case snapshotMore = 5
    /// A `vt-state` or `resized` replay: `meta_len u32`, JSON meta, the replay,
    /// then `pending_len` pending bytes.
    case replay = 6
    /// A shared-memory output ring; its descriptor rides on this frame.
    case ring = 7
    /// The ring's new published end; no payload.
    case ringAdvance = 8
}
