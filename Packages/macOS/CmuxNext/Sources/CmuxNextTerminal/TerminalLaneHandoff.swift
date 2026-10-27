import CmuxNextCompat

/// Bumped on the main actor by each surface change the session's events loop did not ask for (a release
/// or a rebuild, ``TerminalSurfaceRelease``). The loop reads it before each event, one atomic load, and
/// takes the session's current lane on a change (``TerminalLaneHandoff``).
nonisolated final class TerminalSurfaceEpoch: Sendable {
    private let value = Atomic<UInt64>(0)

    var current: UInt64 { value.load(ordering: .acquiring) }

    func advance() {
        value.wrappingAdd(1, ordering: .releasing)
    }
}

/// The session's live surface for its events loop after a release or a rebuild.
nonisolated struct TerminalLaneHandoff: Sendable {
    /// The live surface's lane; nil while released.
    let lane: TerminalOutputLane?
    /// The ``TerminalSurfaceEpoch`` value this lane belongs to.
    let epoch: UInt64
    /// The surface is released: content events are dropped (the rebuild's whole screen carries them).
    let released: Bool
}
