#if canImport(UIKit)
/// Keeps logical capacity on the last settled layout while UIKit owns a
/// keyboard, rotation, or dock animation. Quiet display frames also coalesce
/// safe-area and window geometry delivered in separate layout passes.
struct TerminalViewportGeometryFence {
    private(set) var committed: TerminalViewportSnapshot?
    private var candidate: TerminalViewportSnapshot?
    private var stableFrames = 0
    private static let requiredStableFrames = 3

    mutating func invalidateCandidate() {
        candidate = nil
        stableFrames = 0
    }

    mutating func commitUnfenced(_ snapshot: TerminalViewportSnapshot) {
        committed = snapshot
        invalidateCandidate()
    }

    mutating func sample(_ snapshot: TerminalViewportSnapshot, transitionActive: Bool) -> Bool {
        guard !transitionActive else {
            invalidateCandidate()
            return false
        }
        if committed == snapshot { return true }
        if candidate == snapshot {
            stableFrames += 1
        } else {
            candidate = snapshot
            stableFrames = 1
        }
        guard stableFrames >= Self.requiredStableFrames else { return false }
        committed = snapshot
        invalidateCandidate()
        return true
    }

    /// Authoritative replay can require an immediate local grid apply while
    /// UIKit is moving. It uses the last committed capacity, never a transient
    /// viewport. A first mount has no previous drawable and seeds its capacity.
    mutating func snapshotForApply(_ snapshot: TerminalViewportSnapshot) -> TerminalViewportSnapshot {
        if let committed { return committed }
        committed = snapshot
        return snapshot
    }
}
#endif
