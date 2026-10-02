import Foundation

struct SessionDisplaySnapshot: Codable, Sendable, Equatable {
    var displayID: UInt32?
    /// Stable per-physical-display identity (see `NSScreen.cmuxStableDisplayKey`).
    /// Optional and additive so older persisted snapshots decode unchanged.
    var stableID: String?
    var frame: SessionRectSnapshot?
    var visibleFrame: SessionRectSnapshot?
}
