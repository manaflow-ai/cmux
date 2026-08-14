import Foundation

/// Serializes registration mutations across an actor's suspension points.
/// An actor alone can re-enter while URLSession is awaiting a response. The
/// operation runs in an independent worker so cancelling a UI waiter cannot
/// abandon a request after the server may have committed it.
actor PushRegistrationMutationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        await acquire()
        let worker = Task {
            await operation()
        }
        defer { release() }
        return await worker.value
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}
