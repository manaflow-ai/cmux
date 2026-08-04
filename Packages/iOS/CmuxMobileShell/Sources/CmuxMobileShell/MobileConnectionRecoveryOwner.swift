import Foundation

/// Main-actor authority for one foreground Mac recovery attempt.
///
/// Connection, event-subscription, foreground, and network triggers all claim
/// this owner before starting work. Attempt IDs make cleanup generation-safe:
/// a canceled task from an older attempt can never clear or complete a newer
/// recovery.
@MainActor
final class MobileConnectionRecoveryOwner {
    struct Attempt: Equatable {
        let id: UUID
        let trigger: String
        let sourceConnectionGeneration: UUID
        let deadlineUptimeNanoseconds: UInt64
    }

    enum Phase: Equatable {
        case idle
        case probing(Attempt)
        case redialing(Attempt)
        case validatingReplacement(Attempt, connectionGeneration: UUID)
        case failed(Attempt)
    }

    private(set) var phase: Phase = .idle
    private(set) var task: Task<Void, Never>?
    private var validationWaiters: [
        UUID: [CheckedContinuation<Bool, Never>]
    ] = [:]

    var activeAttempt: Attempt? {
        switch phase {
        case .probing(let attempt), .redialing(let attempt),
             .validatingReplacement(let attempt, _), .failed(let attempt):
            attempt
        case .idle:
            nil
        }
    }

    var isValidatingReplacement: Bool {
        if case .validatingReplacement = phase { return true }
        return false
    }

    var isActive: Bool {
        switch phase {
        case .probing, .redialing, .validatingReplacement:
            true
        case .idle, .failed:
            false
        }
    }

    var isRedialingOrValidating: Bool {
        switch phase {
        case .redialing, .validatingReplacement:
            true
        case .idle, .probing, .failed:
            false
        }
    }

    func begin(
        trigger: String,
        sourceConnectionGeneration: UUID,
        probing: Bool,
        deadlineUptimeNanoseconds: UInt64 = .max
    ) -> Attempt? {
        guard !isActive else { return nil }
        task?.cancel()
        task = nil
        let attempt = Attempt(
            id: UUID(),
            trigger: trigger,
            sourceConnectionGeneration: sourceConnectionGeneration,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        phase = probing ? .probing(attempt) : .redialing(attempt)
        return attempt
    }

    /// A definitive dead-session signal supersedes an in-flight health probe.
    /// The new attempt ID invalidates the probe's eventual cleanup.
    func supersedeProbeWithRedial(
        trigger: String,
        sourceConnectionGeneration: UUID
    ) -> Attempt? {
        guard case .probing(let previousAttempt) = phase else { return nil }
        task?.cancel()
        task = nil
        let attempt = Attempt(
            id: UUID(),
            trigger: trigger,
            sourceConnectionGeneration: sourceConnectionGeneration,
            deadlineUptimeNanoseconds:
                previousAttempt.deadlineUptimeNanoseconds
        )
        phase = .redialing(attempt)
        return attempt
    }

    /// Cancels an in-flight health probe and returns the owner to idle.
    /// Used when the app leaves the foreground: a suspended probe burns its
    /// wall-clock deadline while the process is frozen, so its timeout on
    /// resume is not evidence the connection died. Redialing/validating
    /// attempts are left alone — they own teardown side effects and settle
    /// through their own deadline.
    @discardableResult
    func cancelProbing() -> Bool {
        guard case .probing = phase else { return false }
        task?.cancel()
        task = nil
        phase = .idle
        return true
    }

    func install(_ task: Task<Void, Never>, for attempt: Attempt) {
        guard isCurrent(attempt) else {
            task.cancel()
            return
        }
        self.task = task
    }

    func transitionToRedialing(_ attempt: Attempt) -> Bool {
        guard isCurrent(attempt) else { return false }
        phase = .redialing(attempt)
        return true
    }

    func transitionToValidation(
        _ attempt: Attempt,
        connectionGeneration: UUID
    ) -> Bool {
        guard isCurrent(attempt) else { return false }
        phase = .validatingReplacement(
            attempt,
            connectionGeneration: connectionGeneration
        )
        return true
    }

    func complete(_ attempt: Attempt) -> Bool {
        guard isCurrent(attempt) else { return false }
        phase = .idle
        task = nil
        resolveValidationWaiters(for: attempt.id, result: true)
        return true
    }

    func completeValidation(connectionGeneration: UUID) -> Bool {
        guard case .validatingReplacement(let attempt, let expectedGeneration) = phase,
              expectedGeneration == connectionGeneration else {
            return false
        }
        phase = .idle
        task = nil
        resolveValidationWaiters(for: attempt.id, result: true)
        return true
    }

    func waitForValidationSettlement(_ attempt: Attempt) async -> Bool {
        guard case .validatingReplacement(let active, _) = phase,
              active.id == attempt.id else {
            return false
        }
        return await withCheckedContinuation { continuation in
            validationWaiters[attempt.id, default: []].append(continuation)
        }
    }

    func fail(_ attempt: Attempt) -> Bool {
        guard isCurrent(attempt) else { return false }
        phase = .failed(attempt)
        task = nil
        resolveValidationWaiters(for: attempt.id, result: false)
        return true
    }

    func failReplacement() -> Attempt? {
        let attempt: Attempt
        switch phase {
        case .redialing(let active), .validatingReplacement(let active, _):
            attempt = active
        case .idle, .probing, .failed:
            return nil
        }
        task?.cancel()
        task = nil
        phase = .failed(attempt)
        resolveValidationWaiters(for: attempt.id, result: false)
        return attempt
    }

    func clearTask(for attempt: Attempt) {
        guard isCurrent(attempt) else { return }
        task = nil
    }

    func isCurrent(_ attempt: Attempt) -> Bool {
        switch phase {
        case .probing(let active), .redialing(let active),
             .validatingReplacement(let active, _), .failed(let active):
            active.id == attempt.id
        case .idle:
            false
        }
    }

    func cancel() {
        let attempt = activeAttempt
        task?.cancel()
        task = nil
        phase = .idle
        if let attempt {
            resolveValidationWaiters(for: attempt.id, result: false)
        }
    }

    private func resolveValidationWaiters(
        for attemptID: UUID,
        result: Bool
    ) {
        let waiters = validationWaiters.removeValue(forKey: attemptID) ?? []
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }
}
