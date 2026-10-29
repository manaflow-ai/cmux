import CmuxNextCompat
import CmuxNextTerminalGeometry

/// The host-owned grid of one surface, kept by its output lane (``TerminalOutputLane/lockGrid(_:)``).
///
/// `ghostty_surface_set_grid` is an output function: it runs on the output
/// lane, behind every chunk queued before it, so the mirror reflows at the
/// same point in the byte stream as the owner did. Each new grid gets the
/// next generation; Ghostty refuses an older one. A fresh surface starts a
/// new lock (generation 1).
///
/// The generation is the lane's, not the main actor's: the session's events loop
/// queues a `.resize` lock on the lane in stream order without waiting for main, as Chrome's
/// compositor commits a new viewport size in its own frame sequence (`cc/trees/layer_tree_host_impl.cc`,
/// `LayerTreeHostImpl::SetViewportRectAndScale`) without a round trip to the main thread. Read and
/// written only on the lane's serial queue; the atomics make that sharing data-race free, with no lock.
nonisolated final class TerminalGridLock: Sendable {
    private let generationValue = Atomic<UInt64>(0)
    /// The locked grid, packed as columns << 16 | rows (0: none yet).
    private let lockedValue = Atomic<UInt32>(0)

    /// The last lock's generation (0 before the first).
    var generation: UInt64 { generationValue.load(ordering: .relaxed) }

    /// The locked grid, nil before the first lock or adopt.
    var locked: TerminalGridSize? {
        let packed = lockedValue.load(ordering: .relaxed)
        guard packed != 0 else { return nil }
        return TerminalGridSize(columns: Int(packed >> 16), rows: Int(packed & 0xFFFF))
    }

    /// The `ghostty_surface_set_grid` arguments for `grid`, with the next generation, or nil when `grid`
    /// is already locked or does not fit Ghostty's 16-bit cells. Call on the lane only.
    func next(_ grid: TerminalGridSize) -> (columns: UInt16, rows: UInt16, generation: UInt64)? {
        guard let packed = Self.pack(grid), packed != lockedValue.load(ordering: .relaxed) else { return nil }
        lockedValue.store(packed, ordering: .relaxed)
        let generation = generationValue.load(ordering: .relaxed) &+ 1
        generationValue.store(generation, ordering: .relaxed)
        return (UInt16(truncatingIfNeeded: packed >> 16), UInt16(truncatingIfNeeded: packed & 0xFFFF), generation)
    }

    /// Records `grid` as locked without sending it: a local-history snapshot
    /// restore resized the terminal and its lock to `grid` itself (Ghostty
    /// keeps the lock's generation). Call on the lane only.
    func adopt(_ grid: TerminalGridSize) {
        guard let packed = Self.pack(grid) else { return }
        lockedValue.store(packed, ordering: .relaxed)
    }

    private static func pack(_ grid: TerminalGridSize) -> UInt32? {
        guard grid.columns > 0, grid.rows > 0,
              let columns = UInt16(exactly: grid.columns), let rows = UInt16(exactly: grid.rows) else { return nil }
        return UInt32(columns) << 16 | UInt32(rows)
    }
}
