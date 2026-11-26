import Foundation

/// Actor-isolated byte and event buffer backing one worker subscription.
actor SimulatorWorkerEventStreamStorage {
    private let maximumBufferedBytes: Int
    private let maximumBufferedEvents: Int
    private let onTermination: @Sendable () -> Void
    private var queue: [SimulatorWorkerQueuedEvent] = []
    private var queueHead = 0
    private var bufferedBytes = 0
    private var waiter: SimulatorWorkerEventWaiter?
    private var finished = false
    private var notifiedTermination = false

    init(
        maximumBufferedBytes: Int,
        maximumBufferedEvents: Int,
        onTermination: @escaping @Sendable () -> Void
    ) {
        self.maximumBufferedBytes = Swift.max(1, maximumBufferedBytes)
        self.maximumBufferedEvents = Swift.max(1, maximumBufferedEvents)
        self.onTermination = onTermination
    }

    func yield(
        _ event: SimulatorWorkerEvent,
        byteCount: Int
    ) -> SimulatorWorkerEventStreamYieldResult {
        let chargedBytes = Swift.max(1, byteCount)
        guard !finished else { return .terminated }
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: event)
            return .enqueued
        }
        let eventCount = queue.count - queueHead
        guard eventCount < maximumBufferedEvents,
              chargedBytes <= maximumBufferedBytes - bufferedBytes else {
            return .overflow
        }
        queue.append(SimulatorWorkerQueuedEvent(event: event, byteCount: chargedBytes))
        bufferedBytes += chargedBytes
        return .enqueued
    }

    func next(identifier: UUID) async -> SimulatorWorkerEvent? {
        await withCheckedContinuation { continuation in
            if queueHead < queue.count {
                let queued = queue[queueHead]
                queueHead += 1
                bufferedBytes -= queued.byteCount
                compactQueueIfNeeded()
                continuation.resume(returning: queued.event)
            } else if finished || waiter != nil {
                continuation.resume(returning: nil)
            } else {
                waiter = SimulatorWorkerEventWaiter(
                    identifier: identifier,
                    continuation: continuation
                )
            }
        }
    }

    func cancelNext(identifier: UUID) {
        guard !finished else { return }
        finished = true
        let suspended = waiter?.identifier == identifier ? waiter?.continuation : nil
        waiter = nil
        clearQueue()
        let notify = claimTerminationNotification()
        suspended?.resume(returning: nil)
        if notify { onTermination() }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        let suspended = waiter?.continuation
        waiter = nil
        clearQueue()
        let notify = claimTerminationNotification()
        suspended?.resume(returning: nil)
        if notify { onTermination() }
    }

    private func compactQueueIfNeeded() {
        guard queueHead >= 64, queueHead * 2 >= queue.count else { return }
        queue.removeFirst(queueHead)
        queueHead = 0
    }

    private func clearQueue() {
        queue.removeAll(keepingCapacity: false)
        queueHead = 0
        bufferedBytes = 0
    }

    private func claimTerminationNotification() -> Bool {
        guard !notifiedTermination else { return false }
        notifiedTermination = true
        return true
    }
}
