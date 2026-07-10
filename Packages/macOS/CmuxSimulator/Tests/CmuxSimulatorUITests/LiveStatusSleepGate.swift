import Foundation
@testable import CmuxSimulatorUI

actor LiveStatusSleepGate: SimulatorProcessSleeper {
    private var waiters: [LiveStatusSleepWaiter] = []
    private var starts = 0
    private var cancellations = 0
    private var durations: [Duration] = []
    private var startObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationObservers: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        let id = UUID()
        starts += 1
        resumeObservers(&startObservers, count: starts)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(LiveStatusSleepWaiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advance() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func waitForStarts(_ expected: Int) async {
        guard starts < expected else { return }
        await withCheckedContinuation { startObservers.append((expected, $0)) }
    }

    func waitForCancellations(_ expected: Int) async {
        guard cancellations < expected else { return }
        await withCheckedContinuation { cancellationObservers.append((expected, $0)) }
    }

    func recordedDurations() -> [Duration] { durations }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        cancellations += 1
        resumeObservers(&cancellationObservers, count: cancellations)
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
