public import Foundation

/// Coalesces workspace observation identities at a bounded leading/trailing cadence.
///
/// Record the identity associated with each legacy observation at the app boundary,
/// then consume ``changes`` from one task. The stream keeps one buffered batch;
/// when a slow consumer causes a batch to be displaced, the actor replaces the
/// buffered value with their union so observation remains lossless without
/// scheduling self-sustaining follow-up deliveries.
///
/// ```swift
/// let batch = SidebarWorkspaceObservationBatch(deliveryInterval: .milliseconds(40))
/// let consumer = Task {
///     for await workspaceIds in batch.changes {
///         refreshSidebarRows(workspaceIds)
///     }
/// }
/// await batch.record(workspaceId)
/// await batch.cancel()
/// _ = await consumer.result
/// ```
public actor SidebarWorkspaceObservationBatch {
    /// The single-consumer stream of changed workspace identity batches.
    public nonisolated let changes: AsyncStream<Set<UUID>>

    private let continuation: AsyncStream<Set<UUID>>.Continuation
    private let deliveryInterval: Duration
    private let clock: any Clock<Duration>
    private var pendingWorkspaceIds: Set<UUID> = []
    private var pacingTask: Task<Void, Never>?
    private var isCancelled = false

    /// Creates a lossless observation batcher paced by an injected clock.
    ///
    /// - Parameters:
    ///   - deliveryInterval: The minimum interval between leading/trailing deliveries.
    ///   - clock: The clock that paces delivery windows. Inject a controllable clock in tests.
    public init(
        deliveryInterval: Duration,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        let channel = AsyncStream<Set<UUID>>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        changes = channel.stream
        continuation = channel.continuation
        self.deliveryInterval = deliveryInterval
        self.clock = clock
        continuation.onTermination = { [weak self] _ in
            Task { await self?.cancel() }
        }
    }

    deinit {
        pacingTask?.cancel()
        continuation.finish()
    }

    /// Records one changed workspace identity.
    ///
    /// The first identity after an idle period is delivered immediately. Further
    /// identities are unioned until the active delivery window closes.
    ///
    /// - Parameter workspaceId: The identity whose projected sidebar state changed.
    public func record(_ workspaceId: UUID) {
        record(contentsOf: [workspaceId])
    }

    /// Records a synchronously coalesced set of changed workspace identities.
    ///
    /// - Parameter workspaceIds: The identities whose projected sidebar state changed.
    public func record(contentsOf workspaceIds: Set<UUID>) {
        guard !isCancelled, !workspaceIds.isEmpty else { return }
        pendingWorkspaceIds.formUnion(workspaceIds)
        guard pacingTask == nil else { return }

        emitPendingWorkspaceIds()
        guard !isCancelled else { return }
        startDeliveryWindow()
    }

    /// Stops pacing and finishes ``changes``.
    public func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true

        let task = pacingTask
        pacingTask = nil
        task?.cancel()
        if let task {
            await task.value
        }

        pendingWorkspaceIds.removeAll(keepingCapacity: false)
        continuation.finish()
    }

    private func startDeliveryWindow() {
        let interval = deliveryInterval
        let clock = clock
        pacingTask = Task { [weak self, interval, clock] in
            do {
                // This is the intended bounded delivery cadence, not polling or settling.
                try await clock.sleep(for: interval)
                try Task.checkCancellation()
                await self?.deliveryWindowElapsed()
            } catch {
                // Cancellation ends the owned pacing task without another delivery.
            }
        }
    }

    private func deliveryWindowElapsed() {
        pacingTask = nil
        guard !isCancelled, !pendingWorkspaceIds.isEmpty else { return }

        emitPendingWorkspaceIds()
        guard !isCancelled else { return }
        startDeliveryWindow()
    }

    private func emitPendingWorkspaceIds() {
        guard !pendingWorkspaceIds.isEmpty else { return }
        let batch = pendingWorkspaceIds
        pendingWorkspaceIds.removeAll(keepingCapacity: true)

        switch continuation.yield(batch) {
        case .enqueued:
            break
        case .dropped(let displacedBatch):
            // `bufferingNewest(1)` installed `batch` and returned the older
            // displaced value. Replace the buffer with their union now. If the
            // consumer drained `batch` between these synchronous yields it may
            // observe a duplicate identity, which is harmless; no identity is
            // lost and no pending work can ping-pong forever without new input.
            let mergedBatch = batch.union(displacedBatch)
            if case .terminated = continuation.yield(mergedBatch) {
                terminateFromStream()
            }
        case .terminated:
            terminateFromStream()
        @unknown default:
            terminateFromStream()
        }
    }

    private func terminateFromStream() {
        isCancelled = true
        pendingWorkspaceIds.removeAll(keepingCapacity: false)
        pacingTask?.cancel()
        pacingTask = nil
    }
}
