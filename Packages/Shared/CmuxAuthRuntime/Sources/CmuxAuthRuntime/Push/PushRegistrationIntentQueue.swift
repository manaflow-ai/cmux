import Foundation

/// Runs at most one enable and one disable preparation concurrently.
///
/// Authentication and other pre-request work is not guaranteed to cooperate
/// with task cancellation. Each direction therefore owns one active worker and
/// one quarantined stale worker. This lets one same-direction recovery advance
/// while repeated retries coalesce instead of accumulating unbounded tasks.
actor PushRegistrationIntentQueue {
    private let operation: @Sendable (PushRegistrationIntent) async -> Void
    private var latestGeneration: UInt64 = 0
    private var pendingIntents: [Bool: PushRegistrationIntent] = [:]
    private var runningWorkers: [Bool: PushRegistrationIntentWorker] = [:]
    private var quarantinedWorkers:
        [Bool: PushRegistrationIntentWorker] = [:]
    private var completedIntent: PushRegistrationIntent?
    private var waiters: [UInt64: [UUID: CheckedContinuation<Void, Never>]] = [:]

    /// Creates a queue that delegates each live intent to the registration service.
    init(operation: @escaping @Sendable (PushRegistrationIntent) async -> Void) {
        self.operation = operation
    }

    /// Replaces stale pending work and waits for this intent to be handled.
    func submit(_ intent: PushRegistrationIntent) async {
        guard intent.generation >= latestGeneration else { return }
        let lane = intent.enabled
        if intent == completedIntent,
           pendingIntents[lane] == nil,
           runningWorkers[lane] == nil {
            return
        }

        if intent.generation > latestGeneration {
            latestGeneration = intent.generation
            pendingIntents.removeAll()
            pendingIntents[lane] = intent
            resumeWaiters(before: intent.generation)
            for worker in runningWorkers.values
                where worker.intent.generation < intent.generation {
                worker.task.cancel()
            }
            quarantineStaleRunningWorkerIfPossible(on: lane)
        } else if runningWorkers[lane]?.intent.generation != intent.generation {
            pendingIntents[lane] = intent
        }

        let waiterID = UUID()
        startPendingIntentIfNeeded(on: lane)
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[intent.generation, default: [:]][waiterID] = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(
                generation: intent.generation,
                waiterID: waiterID
            ) }
        })
    }

    private func startPendingIntentIfNeeded(on lane: Bool) {
        guard runningWorkers[lane] == nil,
              let intent = pendingIntents.removeValue(forKey: lane)
        else { return }
        let operation = self.operation
        let workerID = UUID()
        let task = Task { [weak self] in
            await operation(intent)
            await self?.workerCompleted(
                id: workerID,
                intent: intent,
                on: lane
            )
        }
        runningWorkers[lane] = PushRegistrationIntentWorker(
            id: workerID,
            intent: intent,
            task: task
        )
    }

    private func workerCompleted(
        id: UUID,
        intent: PushRegistrationIntent,
        on lane: Bool
    ) {
        if runningWorkers[lane]?.id == id {
            runningWorkers.removeValue(forKey: lane)
            recordCompletion(intent)
            resumeWaiters(for: intent.generation)
            startPendingIntentIfNeeded(on: lane)
            return
        }
        guard quarantinedWorkers[lane]?.id == id else { return }
        quarantinedWorkers.removeValue(forKey: lane)
        recordCompletion(intent)
        resumeWaiters(for: intent.generation)
        quarantineStaleRunningWorkerIfPossible(on: lane)
        startPendingIntentIfNeeded(on: lane)
    }

    private func recordCompletion(_ intent: PushRegistrationIntent) {
        if let completedIntent {
            if intent.generation >= completedIntent.generation {
                self.completedIntent = intent
            }
        } else {
            completedIntent = intent
        }
    }

    /// Moves one superseded worker out of the active slot. A second stalled
    /// worker stays active until either it or the existing quarantine returns,
    /// keeping the lane bounded to two uncooperative operations.
    private func quarantineStaleRunningWorkerIfPossible(on lane: Bool) {
        guard quarantinedWorkers[lane] == nil,
              let pending = pendingIntents[lane],
              let running = runningWorkers[lane],
              running.intent.generation < pending.generation
        else { return }
        running.task.cancel()
        runningWorkers.removeValue(forKey: lane)
        quarantinedWorkers[lane] = running
    }

    private func resumeWaiters(before generation: UInt64) {
        let staleGenerations = waiters.keys.filter { $0 < generation }
        for staleGeneration in staleGenerations {
            resumeWaiters(for: staleGeneration)
        }
    }

    private func resumeWaiters(for generation: UInt64) {
        guard let generationWaiters = waiters.removeValue(forKey: generation)
        else { return }
        for continuation in generationWaiters.values {
            continuation.resume()
        }
    }

    private func cancelWaiter(generation: UInt64, waiterID: UUID) {
        guard var generationWaiters = waiters[generation],
              let continuation = generationWaiters.removeValue(forKey: waiterID)
        else { return }
        if generationWaiters.isEmpty {
            waiters.removeValue(forKey: generation)
        } else {
            waiters[generation] = generationWaiters
        }
        continuation.resume()
    }
}
