import Foundation

/// Serializes permission-onboarding requests produced by the explicit intent
/// boundary so one user turn can never create duplicate windows.
@MainActor
final class ComputerUseOnboardingIntentCoordinator {
    enum Evaluation: Sendable {
        case handled
        case retry
    }

    typealias Signal = ComputerUseIntentBoundary.Signal
    typealias Observation = ComputerUseIntentBoundary.Observation
    typealias Claim = ComputerUseIntentBoundary.Ledger.Claim

    private struct PendingRequest {
        let claim: Claim
    }

    private let evaluate: @MainActor (Signal) async -> Evaluation
    private var ledger = ComputerUseIntentBoundary.Ledger()
    private var pendingRequests: [PendingRequest] = []
    private var drainTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0

    init(
        evaluate: @escaping @MainActor (Signal) async -> Evaluation
    ) {
        self.evaluate = evaluate
    }

    deinit {
        drainTask?.cancel()
    }

    /// Consumes a boundary observation and queues at most one claim per turn.
    func observe(_ observation: Observation) {
        guard let claim = ledger.observe(observation) else {
            return
        }
        pendingRequests.append(PendingRequest(claim: claim))
        drain()
    }

    /// Cancels all pending work when the app coordinator is torn down.
    func stop() {
        lifecycleGeneration &+= 1
        drainTask?.cancel()
        drainTask = nil
        pendingRequests.removeAll()
        ledger.clear()
    }

    /// Test seam that waits for the current single-flight queue to settle.
    func waitForIdle() async {
        while let task = drainTask {
            await task.value
        }
    }

    private func drain() {
        guard drainTask == nil, let request = pendingRequests.first else {
            return
        }
        pendingRequests.removeFirst()
        let generation = lifecycleGeneration
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let completion = await self.evaluate(request.claim.signal)
            guard generation == self.lifecycleGeneration else { return }
            self.ledger.finish(request.claim, completion: Self.ledgerCompletion(completion))
            self.drainTask = nil
            self.drain()
        }
    }

    private static func ledgerCompletion(
        _ evaluation: Evaluation
    ) -> ComputerUseIntentBoundary.Ledger.Completion {
        switch evaluation {
        case .handled:
            .handled
        case .retry:
            .retry
        }
    }
}
