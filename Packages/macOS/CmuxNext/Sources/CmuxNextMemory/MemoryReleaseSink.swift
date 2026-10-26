public import CmuxNextCompat
public import Dispatch
import Darwin

/// The memory coordinator's release sink: it drops what consumers unlinked on a utility-QoS serial
/// queue, and after a critical release pass asks the heap allocators there to give free pages back.
///
/// A release slice runs on the main thread inside a 2 ms budget, so it only unlinks; the free of a
/// CGImage, Data or IOSurface it held happens here (Chrome's `DeleteSoon`,
/// `base/task/sequenced_task_runner.h`). The queue is serial, so ``relieveHeap()`` runs after every
/// drop made before it: the allocators see the pages those frees left empty.
///
/// The heap relief is `malloc_zone_pressure_relief(nil, 0)`, which visits every registered zone,
/// PartitionAlloc's too when in-process CEF installed it, then the fork's PartitionAlloc purge when
/// the composition root has one (Chrome's `partition_alloc::MemoryReclaimer::ReclaimAll()`,
/// `partition_alloc/memory_reclaimer.h`).
///
/// ```swift
/// let sink = MemoryReleaseSink()
/// let coordinator = MemoryCoordinator(pressure: pressure, slicer: slicer, releaseSink: sink)
/// let cache = PreviewImageCache(registry: coordinator, sink: sink)
/// ```
public nonisolated final class MemoryReleaseSink: MemoryReleaseSinking {
    private let queue: DispatchQueue
    private let heapRelief: HeapRelief

    /// Makes a sink that drops values on `queue` and relieves the heap with `heapRelief`.
    ///
    /// - Parameters:
    ///   - queue: A serial queue; the app's runs at utility QoS.
    ///   - heapRelief: What ``relieveHeap()`` runs on `queue`.
    public init(
        queue: DispatchQueue = DispatchQueue(label: "com.cmuxterm.app.next.memory.release-sink", qos: .utility),
        heapRelief: HeapRelief = .system()
    ) {
        self.queue = queue
        self.heapRelief = heapRelief
    }

    public func drop<Value>(_ value: consuming sending Value) {
        // The Mutex makes the value Sendable for the hop; only the queue's one block takes the lock.
        let held = Mutex<Value?>(Optional(consume value))
        queue.async(flags: .inheritQoS) { held.withLock { $0 = nil } }
    }

    /// Runs the heap relief on the queue, after the drops made before this call.
    ///
    /// The coordinator calls it once per escalation to critical, when that pass has finished.
    public func relieveHeap() {
        let relief = heapRelief
        queue.async(flags: .inheritQoS) { relief.relieve() }
    }

    /// Returns when the drops and reliefs asked for before this call have run.
    public func drained() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async(flags: .inheritQoS) { continuation.resume() }
        }
    }
}

extension MemoryReleaseSink {
    /// What the sink runs to make the allocators give free pages back to the system.
    public nonisolated struct HeapRelief: Sendable {
        private let body: @Sendable () -> Void

        /// Makes a relief that runs `body` (a test records the call and its thread).
        ///
        /// - Parameter body: The relief.
        public init(_ body: @escaping @Sendable () -> Void) {
            self.body = body
        }

        /// The app's relief: every malloc zone's pressure relief, then `partitionAllocPurge` when
        /// the Chromium fork offers one.
        ///
        /// - Parameter partitionAllocPurge: The fork's PartitionAlloc purge, or nil.
        /// - Returns: The relief.
        public static func system(partitionAllocPurge: (@Sendable () -> Void)? = nil) -> HeapRelief {
            HeapRelief {
                _ = malloc_zone_pressure_relief(nil, 0)
                partitionAllocPurge?()
            }
        }

        func relieve() {
            body()
        }
    }
}
