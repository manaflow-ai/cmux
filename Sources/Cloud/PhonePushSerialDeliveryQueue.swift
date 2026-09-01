import CmuxPhonePush
import Foundation

/// Bounded, latest-per-id, strictly serial queue for phone push source events.
@MainActor
final class PhonePushSerialDeliveryQueue {
    typealias Sender = @MainActor @Sendable (
        PhonePushRequestEnvelope
    ) async -> PhonePushHTTPResult
    typealias PendingChanged = @MainActor @Sendable (
        [PhonePushRequestEnvelope]
    ) -> Void

    nonisolated static let defaultCapacity = 512

    private let capacity: Int
    private let sender: Sender
    private let pendingChanged: PendingChanged
    private var pending: [PhonePushRequestEnvelope] = []
    private var drainTask: Task<Void, Never>?
    private var drainGeneration = UUID()
    private var isStarted: Bool
    private var inFlightCorrelationID: String?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        capacity: Int = defaultCapacity,
        startsImmediately: Bool = true,
        pendingChanged: @escaping PendingChanged = { _ in },
        sender: @escaping Sender
    ) {
        self.capacity = max(1, capacity)
        self.isStarted = startsImmediately
        self.pendingChanged = pendingChanged
        self.sender = sender
    }

    var pendingCount: Int { pending.count }

    @discardableResult
    func enqueue(_ envelope: PhonePushRequestEnvelope) -> Bool {
        if let key = envelope.coalescingID,
           let index = pending.indices.reversed().first(where: {
               pending[$0].coalescingID == key && !isInFlight(index: $0)
           }) {
            pending.remove(at: index)
            pending.append(envelope)
            publishPending()
            beginDrainIfNeeded()
            return true
        }
        guard pending.count < capacity else { return false }
        pending.append(envelope)
        publishPending()
        beginDrainIfNeeded()
        return true
    }

    /// Preserves dismiss synchronization under a saturated notification queue.
    /// A stale queued banner update is the only safe eviction candidate: the
    /// in-flight request remains untouched, and dismiss envelopes are never
    /// displaced by later bursts.
    @discardableResult
    func enqueuePrioritizingDismiss(_ envelope: PhonePushRequestEnvelope) -> Bool {
        if enqueue(envelope) { return true }
        guard envelope.coalescingID == nil,
              let index = pending.indices.first(where: {
                  pending[$0].coalescingID != nil && !isInFlight(index: $0)
              }) else { return false }
        pending.remove(at: index)
        pending.append(envelope)
        publishPending()
        beginDrainIfNeeded()
        return true
    }

    func restore(_ envelopes: [PhonePushRequestEnvelope]) {
        if let inFlight = pending.first, inFlightCorrelationID != nil {
            // The first slot is already committed to the sender. Restored
            // work joins behind it; otherwise a rebind during an in-flight
            // stop would mistake the restored head for the request on the wire.
            let tail = Self.normalized(
                envelopes + Array(pending.dropFirst())
            )
            let retainedTailCount = max(0, capacity - 1)
            pending = [inFlight] + Array(tail.suffix(retainedTailCount))
        } else {
            let restored = Self.normalized(envelopes + pending)
            pending = Array(restored.suffix(capacity))
        }
        publishPending()
        beginDrainIfNeeded()
    }

    /// Rewrites queued envelopes without touching the request currently being
    /// delivered. Used when the paired iOS variant changes so every future
    /// push follows the latest authenticated pairing target; an in-flight
    /// request is already committed to its original HTTP destination.
    func rebindPending(
        _ transform: (PhonePushRequestEnvelope) -> PhonePushRequestEnvelope
    ) {
        var changed = false
        for index in pending.indices {
            guard !isInFlight(index: index) else {
                continue
            }
            let rebound = transform(pending[index])
            guard rebound != pending[index] else { continue }
            pending[index] = rebound
            changed = true
        }
        guard changed else { return }
        publishPending()
    }

    func start() {
        isStarted = true
        beginDrainIfNeeded()
    }

    /// Pauses delivery without discarding pending envelopes. Used while the
    /// authenticated phone target is unknown; ``start()`` resumes the same
    /// queue after the handshake rebinds every envelope.
    func stop() {
        isStarted = false
        guard inFlightCorrelationID == nil else {
            // Let a request already committed to the wire finish. The drain
            // checks `isStarted` before taking the next slot, so newly queued
            // nil-target work remains parked without a cancellation race.
            return
        }
        drainGeneration = UUID()
        drainTask?.cancel()
        finishIfIdle()
    }

    func cancelAll() {
        drainGeneration = UUID()
        drainTask?.cancel()
        inFlightCorrelationID = nil
        pending.removeAll(keepingCapacity: true)
        publishPending()
        finishIfIdle()
    }

    func retainOnly(accountID: String, generation: UInt64? = nil) {
        let retained = pending.filter {
            $0.expectedAccountID == accountID
                && (generation == nil
                    || $0.expectedSessionGeneration == nil
                    || $0.expectedSessionGeneration == generation)
        }
        guard retained.count != pending.count else { return }
        drainGeneration = UUID()
        drainTask?.cancel()
        inFlightCorrelationID = nil
        pending = retained
        publishPending()
        beginDrainIfNeeded()
    }

    func waitUntilIdle() async {
        // A stopped queue with parked envelopes is intentionally quiescent;
        // callers should not wait forever for a target that may never arrive.
        guard drainTask != nil || (isStarted && !pending.isEmpty) else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    nonisolated static func normalized(
        _ envelopes: [PhonePushRequestEnvelope]
    ) -> [PhonePushRequestEnvelope] {
        var result: [PhonePushRequestEnvelope] = []
        var seenCoalescingIDs = Set<String>()
        result.reserveCapacity(envelopes.count)
        for envelope in envelopes.reversed() {
            if let key = envelope.coalescingID,
               !seenCoalescingIDs.insert(key).inserted {
                continue
            }
            result.append(envelope)
        }
        return Array(result.reversed())
    }

    private func beginDrainIfNeeded() {
        guard isStarted, drainTask == nil, !pending.isEmpty else { return }
        let generation = drainGeneration
        drainTask = Task { [weak self] in
            await self?.drain(generation: generation)
        }
    }

    private func drain(generation: UUID) async {
        while isStarted,
              generation == drainGeneration,
              !Task.isCancelled,
              let envelope = pending.first {
            inFlightCorrelationID = envelope.correlationID
            _ = await sender(envelope)
            guard generation == drainGeneration, !Task.isCancelled else {
                break
            }
            if pending.first == envelope {
                pending.removeFirst()
                publishPending()
            }
            inFlightCorrelationID = nil
        }
        if generation == drainGeneration {
            inFlightCorrelationID = nil
            drainTask = nil
        } else if drainTask?.isCancelled == true {
            inFlightCorrelationID = nil
            drainTask = nil
        }
        beginDrainIfNeeded()
        finishIfIdle()
    }

    private func publishPending() {
        pendingChanged(pending)
    }

    /// The in-flight request always owns the first queue slot. Correlation IDs
    /// are retry identifiers, not queue-entry identity, so a later envelope may
    /// legitimately reuse one while the original request is awaiting a reply.
    private func isInFlight(index: Int) -> Bool {
        inFlightCorrelationID != nil && index == pending.startIndex
    }

    private func finishIfIdle() {
        guard drainTask == nil, (!isStarted || pending.isEmpty) else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
