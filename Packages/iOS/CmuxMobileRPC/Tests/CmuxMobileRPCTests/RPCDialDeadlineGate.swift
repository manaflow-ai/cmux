import Foundation

actor RPCDialDeadlineGate {
    private var continuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var armedCount = 0
    private var armedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func waitForExpiration() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
                armedCount += 1
                let waiters = armedWaiters.filter { $0.count <= armedCount }
                armedWaiters.removeAll { $0.count <= armedCount }
                waiters.forEach { $0.continuation.resume() }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func waitUntilArmed(_ count: Int = 1) async {
        if armedCount >= count { return }
        await withCheckedContinuation { armedWaiters.append((count, $0)) }
    }
    func expire() {
        let pending = continuations.values
        continuations = [:]
        pending.forEach { $0.resume() }
    }
    private func cancel(_ id: UUID) {
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
