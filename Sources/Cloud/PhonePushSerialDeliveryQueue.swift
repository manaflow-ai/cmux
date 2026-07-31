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
           let index = pending.lastIndex(where: {
               $0.coalescingID == key
                   && $0.correlationID != inFlightCorrelationID
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

    func restore(_ envelopes: [PhonePushRequestEnvelope]) {
        let restored = Self.normalized(envelopes + pending)
        pending = Array(restored.suffix(capacity))
        publishPending()
        beginDrainIfNeeded()
    }

    func start() {
        isStarted = true
        beginDrainIfNeeded()
    }

    func cancelAll() {
        drainGeneration = UUID()
        drainTask?.cancel()
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
        pending = retained
        publishPending()
        beginDrainIfNeeded()
    }

    func waitUntilIdle() async {
        guard drainTask != nil || !pending.isEmpty else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    nonisolated static func normalized(
        _ envelopes: [PhonePushRequestEnvelope]
    ) -> [PhonePushRequestEnvelope] {
        var result: [PhonePushRequestEnvelope] = []
        result.reserveCapacity(envelopes.count)
        for envelope in envelopes {
            if let key = envelope.coalescingID,
               let index = result.lastIndex(where: {
                   $0.coalescingID == key
               }) {
                result.remove(at: index)
            }
            result.append(envelope)
        }
        return result
    }

    private func beginDrainIfNeeded() {
        guard isStarted, drainTask == nil, !pending.isEmpty else { return }
        let generation = drainGeneration
        drainTask = Task { [weak self] in
            await self?.drain(generation: generation)
        }
    }

    private func drain(generation: UUID) async {
        while generation == drainGeneration,
              !Task.isCancelled,
              let envelope = pending.first {
            inFlightCorrelationID = envelope.correlationID
            _ = await sender(envelope)
            guard generation == drainGeneration, !Task.isCancelled else {
                break
            }
            if pending.first?.correlationID == envelope.correlationID {
                pending.removeFirst()
                publishPending()
            }
            inFlightCorrelationID = nil
        }
        if generation == drainGeneration {
            inFlightCorrelationID = nil
            drainTask = nil
        } else if drainTask?.isCancelled == true {
            drainTask = nil
        }
        beginDrainIfNeeded()
        finishIfIdle()
    }

    private func publishPending() {
        pendingChanged(pending)
    }

    private func finishIfIdle() {
        guard drainTask == nil, pending.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
