import Foundation

/// A single-consumer worker event stream with explicit byte and count ceilings.
/// Events are delivered directly to a waiting consumer; only producer bursts
/// consume the bounded buffer.
public struct SimulatorWorkerEventStream: AsyncSequence, Sendable {
    public typealias Element = SimulatorWorkerEvent

    public enum YieldResult: Equatable, Sendable {
        case enqueued
        case overflow
        case terminated
    }

    public final class Continuation: @unchecked Sendable {
        private let storage: Storage

        fileprivate init(storage: Storage) {
            self.storage = storage
        }

        public func yield(
            _ event: SimulatorWorkerEvent,
            byteCount: Int = 1
        ) -> YieldResult {
            storage.yield(event, byteCount: byteCount)
        }

        public func finish() {
            storage.finish()
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        private let storage: Storage
        // Retaining the lifetime keeps the subscription registered while an
        // iterator outlives the stream value used to create it.
        private let lifetime: Lifetime

        fileprivate init(storage: Storage, lifetime: Lifetime) {
            self.storage = storage
            self.lifetime = lifetime
        }

        public mutating func next() async -> SimulatorWorkerEvent? {
            let storage = self.storage
            if Task.isCancelled {
                storage.finish()
                return nil
            }
            let identifier = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    storage.installNext(identifier: identifier, continuation: continuation)
                }
            } onCancel: {
                storage.cancelNext(identifier: identifier)
            }
        }
    }

    private let storage: Storage
    private let lifetime: Lifetime

    fileprivate init(storage: Storage, lifetime: Lifetime) {
        self.storage = storage
        self.lifetime = lifetime
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: storage, lifetime: lifetime)
    }

    public static func makeStream(
        maximumBufferedBytes: Int,
        maximumBufferedEvents: Int,
        onTermination: @escaping @Sendable () -> Void
    ) -> (stream: SimulatorWorkerEventStream, continuation: Continuation) {
        let storage = Storage(
            maximumBufferedBytes: maximumBufferedBytes,
            maximumBufferedEvents: maximumBufferedEvents,
            onTermination: onTermination
        )
        let lifetime = Lifetime(storage: storage)
        return (
            SimulatorWorkerEventStream(storage: storage, lifetime: lifetime),
            Continuation(storage: storage)
        )
    }
}

private extension SimulatorWorkerEventStream {
    final class Lifetime: @unchecked Sendable {
        private let storage: Storage

        init(storage: Storage) {
            self.storage = storage
        }

        deinit {
            storage.finish()
        }
    }

    final class Storage: @unchecked Sendable {
        private struct QueuedEvent {
            let event: SimulatorWorkerEvent
            let byteCount: Int
        }

        private struct Waiter {
            let identifier: UUID
            let continuation: CheckedContinuation<SimulatorWorkerEvent?, Never>
        }

        private let lock = NSLock()
        private let maximumBufferedBytes: Int
        private let maximumBufferedEvents: Int
        private let onTermination: @Sendable () -> Void
        private var queue: [QueuedEvent] = []
        private var queueHead = 0
        private var bufferedBytes = 0
        private var waiter: Waiter?
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

        func yield(_ event: SimulatorWorkerEvent, byteCount: Int) -> YieldResult {
            let chargedBytes = Swift.max(1, byteCount)
            lock.lock()
            guard !finished else {
                lock.unlock()
                return .terminated
            }
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.continuation.resume(returning: event)
                return .enqueued
            }
            let eventCount = queue.count - queueHead
            guard eventCount < maximumBufferedEvents,
                  chargedBytes <= maximumBufferedBytes - bufferedBytes else {
                lock.unlock()
                return .overflow
            }
            queue.append(QueuedEvent(event: event, byteCount: chargedBytes))
            bufferedBytes += chargedBytes
            lock.unlock()
            return .enqueued
        }

        func installNext(
            identifier: UUID,
            continuation: CheckedContinuation<SimulatorWorkerEvent?, Never>
        ) {
            var result: SimulatorWorkerEvent?
            var shouldResume = false
            lock.lock()
            if queueHead < queue.count {
                let queued = queue[queueHead]
                queueHead += 1
                bufferedBytes -= queued.byteCount
                result = queued.event
                shouldResume = true
                compactQueueIfNeeded()
            } else if finished || waiter != nil {
                shouldResume = true
            } else {
                waiter = Waiter(identifier: identifier, continuation: continuation)
            }
            lock.unlock()
            if shouldResume {
                continuation.resume(returning: result)
            }
        }

        func cancelNext(identifier: UUID) {
            let suspended: CheckedContinuation<SimulatorWorkerEvent?, Never>?
            let notify: Bool
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            if waiter?.identifier == identifier {
                suspended = waiter?.continuation
            } else {
                suspended = nil
            }
            waiter = nil
            clearQueue()
            notify = claimTerminationNotification()
            lock.unlock()
            suspended?.resume(returning: nil)
            if notify { onTermination() }
        }

        func finish() {
            let suspended: CheckedContinuation<SimulatorWorkerEvent?, Never>?
            let notify: Bool
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            suspended = waiter?.continuation
            waiter = nil
            clearQueue()
            notify = claimTerminationNotification()
            lock.unlock()
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
}
