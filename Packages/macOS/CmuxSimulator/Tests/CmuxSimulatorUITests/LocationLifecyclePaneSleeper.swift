import Foundation
@testable import CmuxSimulatorUI

actor LocationLifecyclePaneSleeper: SimulatorProcessSleeper {
    private var waiters: [LocationLifecycleSleepWaiter] = []
    private var startCount = 0
    private var cancellationCount = 0
    private var startObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationObservers: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(for duration: Duration) async throws {
        _ = duration
        let id = UUID()
        startCount += 1
        resumeObservers(&startObservers, count: startCount)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(LocationLifecycleSleepWaiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advance() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func waitForStartCount(_ count: Int) async {
        guard startCount < count else { return }
        await withCheckedContinuation { startObservers.append((count, $0)) }
    }

    func waitForCancellationCount(_ count: Int) async {
        guard cancellationCount < count else { return }
        await withCheckedContinuation { cancellationObservers.append((count, $0)) }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        cancellationCount += 1
        resumeObservers(&cancellationObservers, count: cancellationCount)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeObservers(
        _ observers: inout [(Int, CheckedContinuation<Void, Never>)],
        count: Int
    ) {
        let ready = observers.filter { $0.0 <= count }
        observers.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
    }
}
