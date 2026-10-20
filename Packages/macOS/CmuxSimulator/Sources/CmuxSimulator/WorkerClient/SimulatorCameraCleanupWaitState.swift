actor SimulatorCameraCleanupWaitState {
    private var outcome: SimulatorCameraCleanupWaitOutcome?
    private var continuation: CheckedContinuation<SimulatorCameraCleanupWaitOutcome, Never>?
    private var completionWatcher: Task<Void, Never>?
    private var deadlineWatcher: Task<Void, Never>?

    func wait(
        for cleanup: Task<SimulatorCameraCleanupResult, Never>,
        timeout: Duration,
        sleeper: any SimulatorWorkerSleeping
    ) async -> SimulatorCameraCleanupWaitOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let outcome {
                    continuation.resume(returning: outcome)
                    return
                }
                self.continuation = continuation
                completionWatcher = Task {
                    let result = await cleanup.value
                    self.finish(.completed(result))
                }
                deadlineWatcher = Task {
                    do {
                        try await sleeper.sleep(for: timeout)
                    } catch {
                        self.finish(.timedOut)
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self.finish(.timedOut)
                }
            }
        } onCancel: {
            Task { await self.finish(.cancelled) }
        }
    }

    private func finish(_ outcome: SimulatorCameraCleanupWaitOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        completionWatcher?.cancel()
        deadlineWatcher?.cancel()
        completionWatcher = nil
        deadlineWatcher = nil
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}
