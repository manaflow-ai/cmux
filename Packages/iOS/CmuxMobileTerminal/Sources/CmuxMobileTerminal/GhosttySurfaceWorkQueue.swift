import Foundation

/// Owns the serial libghostty work queue for one surface generation.
/// All mutable state is accessed only from `queue`; main-actor code replaces whole instances on recovery.
final class GhosttySurfaceWorkQueue: @unchecked Sendable {
    let queue: DispatchQueue
    #if DEBUG
    /// Accessed only from ``queue`` while producing DEBUG accessibility snapshots.
    var lastAccessibilityTextTime: CFTimeInterval = 0
    /// Accessed only from ``queue``; rate-limits slow-output perf log lines.
    var lastOutputPerfLogTime: CFTimeInterval = 0
    /// Accessed only from ``queue``; rate-limits slow-render perf log lines.
    var lastRenderPerfLogTime: CFTimeInterval = 0
    #endif
    /// Accessed only from ``queue``: throttles the viewport content-bottom
    /// measurement for the keyboard blank-space absorption.
    var lastContentBottomTime: CFTimeInterval = 0
    /// Accessed only from ``queue``: last observed terminal grid dimensions.
    private var observedGridColumns = 0
    private var observedGridRows = 0
    /// Accessed only from ``queue``: increments whenever the observed grid
    /// changes. A grid change reflows the surface's existing content, so a
    /// render-grid delta diffed against the pre-reflow content may no longer
    /// patch it (``GhosttySurfaceView/processOutput`` fences on this).
    private(set) var observedGridGeneration: UInt64 = 0
    /// Accessed only from ``queue``: the observed-grid generation at the most
    /// recently applied render-grid frame, or nil before any frame applied.
    var gridGenerationAtLastRenderGridApply: UInt64?

    /// Record the currently measured grid, bumping the generation when it
    /// changed. Must be called from ``queue``.
    @discardableResult
    func noteObservedGrid(columns: Int, rows: Int) -> UInt64 {
        if columns != observedGridColumns || rows != observedGridRows {
            observedGridColumns = columns
            observedGridRows = rows
            observedGridGeneration &+= 1
        }
        return observedGridGeneration
    }

    init(generation: UInt64) {
        // carve-out justification: serial event-delivery queue for low-level libghostty C calls; not used as a lock.
        queue = DispatchQueue(
            label: "dev.cmux.GhosttySurfaceView.output.\(generation)",
            qos: .userInitiated
        )
    }

    func async(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}
