import Foundation

/// A single-consumer queue of accepted streams that fails waiters on close.
///
/// Delivery and cancellation serialize under one lock: a canceled `next()`
/// either wins (its waiter is removed and resumed with `CancellationError`)
/// or delivery already won (the id is forgotten and cancellation is a no-op),
/// so a stream can neither be swallowed by a dead waiter nor leak state.
final class DirectQuicInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [DirectQuicStream] = []
    private var waiters: [(id: UUID, continuation: CheckedContinuation<DirectQuicStream, any Error>)] = []
    /// Ids between `next()` entry and registration or immediate resolution.
    /// Only these can receive a pre-registration cancel marker, so a cancel
    /// that loses the race to delivery records nothing and nothing leaks.
    private var unregisteredIDs: Set<UUID> = []
    /// Ids whose cancellation fired before their continuation registered.
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var finished = false
    private let maximumPending = DirectQuicProtocol().maximumStreams

    /// Enqueues one accepted stream, delivering it to the oldest live waiter.
    /// Returns false when the inbox is closed or full.
    func offer(_ stream: DirectQuicStream) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        if !waiters.isEmpty {
            // Resuming under the lock keeps delivery atomic with
            // cancellation: a cancel that runs after this finds no waiter
            // and does nothing, because delivery won.
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: stream)
            lock.unlock()
            return true
        }
        guard pending.count < maximumPending else {
            lock.unlock()
            return false
        }
        pending.append(stream)
        lock.unlock()
        return true
    }

    /// The next accepted stream, in arrival order.
    func next() async throws -> DirectQuicStream {
        let id = UUID()
        _ = lock.withLock { unregisteredIDs.insert(id) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                unregisteredIDs.remove(id)
                if cancelledBeforeRegistration.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if !pending.isEmpty {
                    let stream = pending.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: stream)
                    return
                }
                if finished {
                    lock.unlock()
                    continuation.resume(throwing: DirectQuicError.connectionClosed("closed"))
                    return
                }
                waiters.append((id, continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: index)
                waiter.continuation.resume(throwing: CancellationError())
                lock.unlock()
                return
            }
            // Not yet registered: mark it so registration fails immediately.
            // Otherwise delivery already won and there is nothing to record.
            if unregisteredIDs.contains(id) {
                cancelledBeforeRegistration.insert(id)
            }
            lock.unlock()
        }
    }

    /// Ends the inbox: live waiters fail, buffered streams are reset.
    func finish() {
        lock.lock()
        finished = true
        let liveWaiters = waiters
        let dropped = pending
        waiters.removeAll()
        unregisteredIDs.removeAll()
        cancelledBeforeRegistration.removeAll()
        pending.removeAll()
        lock.unlock()
        for waiter in liveWaiters {
            waiter.continuation.resume(throwing: DirectQuicError.connectionClosed("closed"))
        }
        for stream in dropped { Task { try? await stream.reset(errorCode: 0) } }
    }
}
