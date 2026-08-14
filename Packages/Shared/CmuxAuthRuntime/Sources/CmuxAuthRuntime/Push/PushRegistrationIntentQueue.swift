import Foundation

/// Runs at most one enable and one disable preparation concurrently.
///
/// Authentication and other pre-request work is not guaranteed to cooperate
/// with task cancellation. A stalled enable must therefore remain owned while
/// a newer opt-out advances on the independent disable lane. Repeated intents
/// on either lane replace one pending value instead of accumulating tasks.
actor PushRegistrationIntentQueue {
    private enum Lane: Hashable {
        case enable
        case disable

        init(_ intent: PushRegistrationIntent) {
            self = intent.enabled ? .enable : .disable
        }
    }

    private struct RunningIntent {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private let operation: @Sendable (PushRegistrationIntent) async -> Void
    private var latestGeneration: UInt64 = 0
    private var pendingIntents: [Lane: PushRegistrationIntent] = [:]
    private var runningIntents: [Lane: RunningIntent] = [:]
    private var completedIntent: PushRegistrationIntent?
    private var waiters: [UInt64: [UUID: CheckedContinuation<Void, Never>]] = [:]

    /// Creates a queue that delegates each live intent to the registration service.
    init(operation: @escaping @Sendable (PushRegistrationIntent) async -> Void) {
        self.operation = operation
    }

    /// Replaces stale pending work and waits for this intent to be handled.
    func submit(_ intent: PushRegistrationIntent) async {
        guard intent.generation >= latestGeneration else { return }
        let lane = Lane(intent)
        if intent == completedIntent,
           pendingIntents[lane] == nil,
           runningIntents[lane] == nil {
            return
        }

        if intent.generation > latestGeneration {
            latestGeneration = intent.generation
            pendingIntents.removeAll()
            pendingIntents[lane] = intent
            resumeWaiters(before: intent.generation)
            for running in runningIntents.values
                where running.generation < intent.generation {
                running.task.cancel()
            }
        } else if runningIntents[lane]?.generation != intent.generation {
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

    private func startPendingIntentIfNeeded(on lane: Lane) {
        guard runningIntents[lane] == nil,
              let intent = pendingIntents.removeValue(forKey: lane)
        else { return }
        let operation = self.operation
        let task = Task { [weak self] in
            await operation(intent)
            await self?.intentCompleted(intent, on: lane)
        }
        runningIntents[lane] = RunningIntent(
            generation: intent.generation,
            task: task
        )
    }

    private func intentCompleted(
        _ intent: PushRegistrationIntent,
        on lane: Lane
    ) {
        guard runningIntents[lane]?.generation == intent.generation else {
            return
        }
        runningIntents.removeValue(forKey: lane)
        if let completedIntent {
            if intent.generation >= completedIntent.generation {
                self.completedIntent = intent
            }
        } else {
            completedIntent = intent
        }
        resumeWaiters(for: intent.generation)
        startPendingIntentIfNeeded(on: lane)
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
