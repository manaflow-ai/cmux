import Foundation

actor RPCDialDeadlineGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var armedWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let waiters = armedWaiters
                armedWaiters = []
                waiters.forEach { $0.resume() }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func waitUntilArmed() async {
        if continuation != nil { return }
        await withCheckedContinuation { armedWaiters.append($0) }
    }
    func expire() {
        continuation?.resume()
        continuation = nil
    }
    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
