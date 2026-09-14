import Foundation

/// Owns the serial libghostty work queue for one surface generation.
/// All mutable state is accessed only from `queue`; main-actor code replaces whole instances on recovery.
final class GhosttySurfaceWorkQueue: @unchecked Sendable {
    let queue: DispatchQueue
    private let pendingLock = NSLock()
    private var pendingPriority: [@Sendable () -> Void] = []
    private var pendingNormal: [@Sendable () -> Void] = []
    private var priorityHead = 0
    private var normalHead = 0
    private var isRunning = false
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

    /// Check the last grid recorded by a geometry or exact render-grid pass.
    /// Must be called from ``queue``. This keeps the direct primary-screen
    /// delta path fenced against stale producer dimensions without another
    /// libghostty surface read.
    func observedGridMatches(columns: Int, rows: Int) -> Bool {
        observedGridColumns > 0
            && observedGridRows > 0
            && observedGridColumns == columns
            && observedGridRows == rows
    }

    /// Human-readable form of the cached grid for fence diagnostics. Must be
    /// called from ``queue``.
    var observedGridDescription: String {
        observedGridColumns > 0 && observedGridRows > 0
            ? "\(observedGridColumns)x\(observedGridRows)"
            : "unknown"
    }

    init(generation: UInt64) {
        // carve-out justification: serial event-delivery queue for low-level libghostty C calls; not used as a lock.
        queue = DispatchQueue(
            label: "dev.cmux.GhosttySurfaceView.output.\(generation)",
            qos: .userInitiated
        )
    }

    func async(
        _ work: @escaping @Sendable () -> Void,
        priority: Bool = false
    ) {
        enqueue(work, priority: priority)
    }

    /// Enqueue latency-sensitive interaction work ahead of queued repaint work.
    /// The same serial worker still executes every Ghostty call, so priority
    /// changes scheduling only and never permits concurrent surface mutation.
    func asyncPriority(_ work: @escaping @Sendable () -> Void) {
        enqueue(work, priority: true)
    }

    private func enqueue(_ work: @escaping @Sendable () -> Void, priority: Bool) {
        pendingLock.lock()
        if priority {
            pendingPriority.append(work)
        } else {
            pendingNormal.append(work)
        }
        let shouldStart = !isRunning
        if shouldStart { isRunning = true }
        pendingLock.unlock()
        guard shouldStart else { return }
        scheduleNext()
    }

    private func scheduleNext() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let work: (@Sendable () -> Void)?
            if self.priorityHead < self.pendingPriority.count {
                work = self.pendingPriority[self.priorityHead]
                self.priorityHead += 1
            } else if self.normalHead < self.pendingNormal.count {
                work = self.pendingNormal[self.normalHead]
                self.normalHead += 1
            } else {
                work = nil
                self.isRunning = false
                self.pendingPriority.removeAll(keepingCapacity: true)
                self.pendingNormal.removeAll(keepingCapacity: true)
                self.priorityHead = 0
                self.normalHead = 0
            }
            if self.priorityHead > 32, self.priorityHead * 2 >= self.pendingPriority.count {
                self.pendingPriority.removeFirst(self.priorityHead)
                self.priorityHead = 0
            }
            if self.normalHead > 32, self.normalHead * 2 >= self.pendingNormal.count {
                self.pendingNormal.removeFirst(self.normalHead)
                self.normalHead = 0
            }
            self.pendingLock.unlock()
            guard let work else { return }
            work()
            self.scheduleNext()
        }
    }
}
