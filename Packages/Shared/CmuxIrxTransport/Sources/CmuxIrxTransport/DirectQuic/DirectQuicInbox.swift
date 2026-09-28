import Foundation

/// A single-consumer queue of accepted streams that fails waiters on close.
/// A canceled `next()` removes its own waiter, so a stream can never be
/// delivered to a task that stopped listening.
final class DirectQuicInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [DirectQuicStream] = []
    private var waiters: [(id: UUID, continuation: CheckedContinuation<DirectQuicStream, any Error>)] = []
    private var cancelledWaiterIDs: Set<UUID> = []
    private var finished = false
    private static let maximumPending = DirectQuicProtocol().maximumStreams

    /// Returns false when the inbox is closed or full.
    func offer(_ stream: DirectQuicStream) -> Bool {
        let waiter = lock.withLock { () -> CheckedContinuation<DirectQuicStream, any Error>?? in
            guard !finished else { return .none }
            if !waiters.isEmpty { return .some(waiters.removeFirst().continuation) }
            guard pending.count < Self.maximumPending else { return .none }
            pending.append(stream)
            return .some(nil)
        }
        switch waiter {
        case .none: return false
        case .some(nil): return true
        case let .some(continuation?):
            continuation.resume(returning: stream)
            return true
        }
    }

    /// The next accepted stream, waiting for one when none is pending.
    /// Throws when the inbox closes or the waiting task is cancelled.
    func next() async throws -> DirectQuicStream {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resolved: Result<DirectQuicStream, any Error>? = lock.withLock {
                    if cancelledWaiterIDs.remove(id) != nil { return .failure(CancellationError()) }
                    if !pending.isEmpty { return .success(pending.removeFirst()) }
                    if finished { return .failure(DirectQuicError.connectionClosed("closed")) }
                    waiters.append((id, continuation))
                    return nil
                }
                if let resolved { continuation.resume(with: resolved) }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<DirectQuicStream, any Error>? in
                if let index = waiters.firstIndex(where: { $0.id == id }) {
                    return waiters.remove(at: index).continuation
                }
                cancelledWaiterIDs.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Closes the inbox: fails every waiter and resets undelivered streams.
    func finish() {
        let (waiters, dropped) = lock.withLock { () -> ([CheckedContinuation<DirectQuicStream, any Error>], [DirectQuicStream]) in
            finished = true
            defer {
                self.waiters.removeAll()
                cancelledWaiterIDs.removeAll()
                pending.removeAll()
            }
            return (self.waiters.map(\.continuation), pending)
        }
        for waiter in waiters { waiter.resume(throwing: DirectQuicError.connectionClosed("closed")) }
        for stream in dropped { Task { try? await stream.reset(errorCode: 0) } }
    }
}
