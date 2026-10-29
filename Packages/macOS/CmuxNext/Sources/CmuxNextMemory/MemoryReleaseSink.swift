public import CmuxNextCompat
public import Dispatch
import Darwin
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// The memory coordinator's release sink: it drops what consumers unlinked on a utility-QoS serial
/// queue, and after a critical release pass asks the heap allocators there to give free pages back.
///
/// A release slice runs on the main thread inside a 2 ms budget, so it only unlinks; the free of a
/// CGImage, Data or IOSurface it held happens here (Chrome's `DeleteSoon`,
/// `base/task/sequenced_task_runner.h`). The queue is serial, so ``relieveHeap()`` runs after every
/// drop made before it: the allocators see the pages those frees left empty.
///
/// The heap relief is `malloc_zone_pressure_relief(nil, 0)`, which relieves every registered zone
/// that has a `pressure_relief`. PartitionAlloc's zone has none (`g_mac_malloc_zone.pressure_relief
/// = nullptr`, `partition_alloc/shim/allocator_shim_override_apple_default_zone.h`), so the
/// in-process CEF heap is not relieved by it; that takes the fork's purge (Chrome's
/// `partition_alloc::MemoryReclaimer::Instance()->ReclaimAll()`, `partition_alloc/memory_reclaimer.h`),
/// which the fork does not export yet. Until the follow-up task "Fork PartitionAlloc purge"
/// adds that entry and passes it in AppServices+Memory.swift, the app's
/// ``HeapRelief/system(partitionAllocPurge:)`` gets nil.
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
        _ = try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
            queue.async(flags: .inheritQoS) { continuation.resume(returning: ()) }
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

        /// The app's relief: the pressure relief of every malloc zone that has one (PartitionAlloc's
        /// has none), then `partitionAllocPurge` when the Chromium fork offers one.
        ///
        /// - Parameter partitionAllocPurge: The fork's PartitionAlloc purge, or nil (the app passes
        ///   nil until the fork exports `MemoryReclaimer::ReclaimAll()`).
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
