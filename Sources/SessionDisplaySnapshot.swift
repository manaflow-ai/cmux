import Foundation
import CmuxWorkspaces

struct SessionDisplaySnapshot: Codable, Sendable, Equatable {
    var displayID: UInt32?
    /// Stable per-physical-display identity (see `NSScreen.cmuxStableDisplayKey`).
    /// Optional and additive so older persisted snapshots decode unchanged.
    var stableID: String?
    var frame: SessionRectSnapshot?
    var visibleFrame: SessionRectSnapshot?
}

#if DEBUG
extension SessionDisplaySnapshot {
    var debugLogDescription: String {
        let displayIdText = displayID.map(String.init) ?? "nil"
        let stableIdText = stableID ?? "nil"
        return "id=\(displayIdText) " +
            "stable=\(stableIdText) " +
            "frame={\(frame?.debugLogDescription ?? "nil")} " +
            "visible={\(visibleFrame?.debugLogDescription ?? "nil")}"
    }
}
#endif
