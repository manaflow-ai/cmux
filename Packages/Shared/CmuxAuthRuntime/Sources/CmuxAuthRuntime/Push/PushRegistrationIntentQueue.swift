import Foundation

/// Runs one preference mutation at a time while replacing stale pending work.
///
/// A committed network request cannot be canceled safely, but a preference
/// intent that has not started has no value after a newer toggle arrives. The
/// queue therefore keeps one in-flight operation, one latest pending intent,
/// and only the waiters for those live generations.
actor PushRegistrationIntentQueue {
    private let operation: @Sendable (PushRegistrationIntent) async -> Void
    private var latestGeneration: UInt64 = 0
    private var pendingIntent: PushRegistrationIntent?
    private var runningGeneration: UInt64?
    private var completedIntent: PushRegistrationIntent?
    private var workerTask: Task<Void, Never>?
    private var waiters: [UInt64: [UUID: CheckedContinuation<Void, Never>]] = [:]

    /// Creates a queue that delegates each live intent to the registration service.
    init(operation: @escaping @Sendable (PushRegistrationIntent) async -> Void) {
        self.operation = operation
    }

    /// Replaces stale pending work and waits for this intent to be handled.
    func submit(_ intent: PushRegistrationIntent) async {
        guard intent.generation >= latestGeneration else { return }
        if intent == completedIntent,
           pendingIntent == nil,
           runningGeneration == nil {
            return
        }
        if intent.generation > latestGeneration {
            latestGeneration = intent.generation
            pendingIntent = intent
            resumeWaiters(before: intent.generation)
        } else if runningGeneration != intent.generation {
            pendingIntent = intent
        }

        let waiterID = UUID()
        if workerTask == nil {
            let operation = self.operation
            workerTask = Task { [weak self] in
                await self?.drain(operation: operation)
            }
        }
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

    private func drain(
        operation: @escaping @Sendable (PushRegistrationIntent) async -> Void
    ) async {
        while let intent = pendingIntent {
            pendingIntent = nil
            runningGeneration = intent.generation
            await operation(intent)
            runningGeneration = nil
            completedIntent = intent
            resumeWaiters(for: intent.generation)
        }
        workerTask = nil
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
