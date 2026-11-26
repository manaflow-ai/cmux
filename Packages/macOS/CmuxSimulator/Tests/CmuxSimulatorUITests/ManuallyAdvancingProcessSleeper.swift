import Foundation
@testable import CmuxSimulatorUI

actor ManuallyAdvancingProcessSleeper: SimulatorProcessSleeper {
    private(set) var callCount = 0
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []
    private var observationWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep(for duration: Duration) async throws {
        _ = duration
        callCount += 1
        let ready = observationWaiters.filter { $0.count <= callCount }
        observationWaiters.removeAll { $0.count <= callCount }
        ready.forEach { $0.continuation.resume() }
        await withCheckedContinuation { continuation in
            sleepWaiters.append(continuation)
        }
    }

    func advance() {
        guard !sleepWaiters.isEmpty else { return }
        sleepWaiters.removeFirst().resume()
    }

    func waitForCallCount(_ count: Int) async {
        guard callCount < count else { return }
        await withCheckedContinuation { continuation in
            observationWaiters.append((count, continuation))
        }
    }
}
