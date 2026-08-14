import Foundation

/// Serializes registration mutations across an actor's suspension points.
/// An actor alone can re-enter while URLSession is awaiting a response. The
/// operation runs in an independent worker so cancelling a UI waiter cannot
/// abandon a request after the server may have committed it.
actor PushRegistrationMutationGate {
    private var isHeld = false
    private var waiters: [(
        id: UUID,
        continuation: CheckedContinuation<Bool, Never>
    )] = []

    func withLock<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        guard await acquire() else { return nil }
        let worker = Task {
            await operation()
        }
        defer { release() }
        return await worker.value
    }

    private func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard isHeld else {
            isHeld = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id: id, continuation: continuation))
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id: id) }
        })
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func release() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: true)
            return
        }
        isHeld = false
    }
}
