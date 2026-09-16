import Foundation
import CmuxMobileDiagnostics

/// Owns the serial libghostty work queue for one surface generation.
/// Pending work is protected by `pendingLock`; surface state is accessed only from `queue`.
/// Main-actor code replaces whole instances on recovery.
final class GhosttySurfaceWorkQueue: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        let pendingCount: Int
        let rejectedCount: UInt64
    }

    let queue: DispatchQueue
    private let pendingLock = NSLock()
    private var pendingPriority: [@Sendable () -> Void] = []
    private var pendingNormal: [@Sendable () -> Void] = []
    private var priorityHead = 0
    private var normalHead = 0
    private var priorityBurst = 0
    private var rejectedCount: UInt64 = 0
    private static let maximumPriorityBurst = 4
    private static let maximumPendingOperations = 256
    private var isRunning = false
    #if DEBUG
    let traceID = UUID().uuidString.lowercased()
    private var traceOperation: UInt64 = 0 // Protected by pendingLock.
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

    @discardableResult
    func async(
        _ work: @escaping @Sendable () -> Void,
        priority: Bool = false,
        label: String = "normal"
    ) -> Bool {
        enqueue(work, priority: priority, label: label)
    }

    /// Enqueue latency-sensitive interaction work ahead of queued repaint work.
    /// The same serial worker still executes every Ghostty call, so priority
    /// changes scheduling only and never permits concurrent surface mutation.
    @discardableResult
    func asyncPriority(
        _ work: @escaping @Sendable () -> Void,
        label: String = "priority"
    ) -> Bool {
        enqueue(work, priority: true, label: label)
    }

    func snapshot() -> Snapshot {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return Snapshot(
            pendingCount: pendingPriority.count - priorityHead
                + pendingNormal.count - normalHead,
            rejectedCount: rejectedCount
        )
    }

    private func enqueue(
        _ work: @escaping @Sendable () -> Void,
        priority: Bool,
        label: String
    ) -> Bool {
        #if DEBUG
        let enqueuedAt = MobileLatencyTrace.captureTime()
        #endif
        pendingLock.lock()
        let pendingCount = pendingPriority.count - priorityHead + pendingNormal.count - normalHead
        if pendingCount >= Self.maximumPendingOperations {
            rejectedCount &+= 1
            pendingLock.unlock()
            #if DEBUG
            MobileLatencyTrace.stamp(
                "oq.reject",
                "q=\(self.traceID) label=\(label) depth=\(pendingCount)"
            )
            #endif
            return false
        }
        var operation = work
        #if DEBUG
        let traceID = self.traceID
        let operationID = traceOperation
        if let enqueuedAt {
            traceOperation &+= 1
            operation = { [work] in
                MobileLatencyTrace.stampElapsed("oq.wait", since: enqueuedAt) { elapsed in
                    "q=\(traceID) op=\(operationID) label=\(label) us=\(elapsed)"
                }
                let startedAt = MobileLatencyTrace.captureTime()
                work()
                MobileLatencyTrace.stampElapsed("oq.run", since: startedAt) { elapsed in
                    "q=\(traceID) op=\(operationID) label=\(label) us=\(elapsed)"
                }
            }
        }
        #endif
        if priority {
            pendingPriority.append(operation)
        } else {
            pendingNormal.append(operation)
        }
        #if DEBUG
        let depthAfterEnqueue = pendingCount + 1
        #endif
        let shouldStart = !isRunning
        if shouldStart { isRunning = true }
        pendingLock.unlock()
        #if DEBUG
        if let enqueuedAt {
            MobileLatencyTrace.stamp(
                "oq.enqueue",
                at: enqueuedAt,
                "q=\(traceID) op=\(operationID) label=\(label) priority=\(priority ? 1 : 0) depth=\(depthAfterEnqueue)"
            )
        }
        #endif
        guard shouldStart else { return true }
        scheduleNext()
        return true
    }

    private func scheduleNext() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let work: (@Sendable () -> Void)?
            let shouldRunPriority = self.priorityHead < self.pendingPriority.count
                && (self.priorityBurst < Self.maximumPriorityBurst || self.normalHead >= self.pendingNormal.count)
            if shouldRunPriority {
                work = self.pendingPriority[self.priorityHead]
                self.priorityHead += 1
                self.priorityBurst += 1
            } else if self.normalHead < self.pendingNormal.count {
                work = self.pendingNormal[self.normalHead]
                self.normalHead += 1
                self.priorityBurst = 0
            } else {
                work = nil
                self.isRunning = false
                self.priorityBurst = 0
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
