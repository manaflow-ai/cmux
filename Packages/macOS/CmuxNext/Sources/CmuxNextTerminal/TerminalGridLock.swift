import CmuxNextTerminalGeometry
import GhosttyNextKit

/// The host-owned grid of one surface, sent to Ghostty in stream order.
///
/// `ghostty_surface_set_grid` is an output function: it runs on the output
/// lane, behind every chunk queued before it, so the mirror reflows at the
/// same point in the byte stream as the owner did. Each new grid gets the
/// next generation; Ghostty refuses an older one. A fresh surface starts a
/// new lock (generation 1).
struct TerminalGridLock {
    private(set) var generation: UInt64 = 0
    private(set) var locked: TerminalGridSize?

    /// Queues the lock for `grid` unless it is already the locked grid.
    @MainActor
    mutating func lock(_ grid: TerminalGridSize, on lane: TerminalOutputLane) {
        guard grid != locked,
              let columns = UInt16(exactly: grid.columns), let rows = UInt16(exactly: grid.rows) else { return }
        generation += 1
        locked = grid
        let generation = generation
        lane.perform { surface in
            _ = ghostty_surface_set_grid(surface, columns, rows, generation)
        }
    }

    /// Records `grid` as locked without sending it: a local-history snapshot
    /// restore resized the terminal and its lock to `grid` itself (Ghostty
    /// keeps the lock's generation).
    mutating func adopt(_ grid: TerminalGridSize) {
        locked = grid
    }
}
