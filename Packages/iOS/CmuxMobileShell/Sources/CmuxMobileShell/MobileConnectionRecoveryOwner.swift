import CMUXMobileCore
internal import CmuxMobileSupport
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

        /// Process-local recovery trace handle safe to place in a report.
        var diagnosticID: UInt32 {
            DiagnosticCorrelation().handle(for: id.uuidString) ?? 1
        }
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

    /// Backoff and one-shot task for a terminal event stream that ended before
    /// delivering an event. Keeping this beside the connection-recovery task
    /// makes owner cancellation invalidate every recovery continuation.
    private(set) var deadTerminalEventStreamRedialBackoff =
        MobileDeadStreamRedialBackoff()
    private var deadTerminalEventStreamRedialTask: Task<Void, Never>?
    private var deadTerminalEventStreamRedialGeneration = UUID()

    /// Number of barren streams in the current session, used by recovery
    /// diagnostics without exposing the mutable backoff itself.
    var deadTerminalEventStreamBarrenCount: Int {
        deadTerminalEventStreamRedialBackoff.consecutiveBarrenRedials
    }

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

    /// Claims a new probe or redial attempt when no recovery is active.
    func begin(
        trigger: String,
        sourceConnectionGeneration: UUID,
        probing: Bool
    ) -> Attempt? {
        guard !isActive else { return nil }
        task?.cancel()
        task = nil
        cancelDeadTerminalEventStreamRedial()
        let attempt = Attempt(
            id: UUID(),
            trigger: trigger,
            sourceConnectionGeneration: sourceConnectionGeneration
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
        guard case .probing = phase else { return nil }
        task?.cancel()
        task = nil
        cancelDeadTerminalEventStreamRedial()
        let attempt = Attempt(
            id: UUID(),
            trigger: trigger,
            sourceConnectionGeneration: sourceConnectionGeneration
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
        return true
    }

    func completeValidation(connectionGeneration: UUID) -> Bool {
        guard case .validatingReplacement(_, let expectedGeneration) = phase,
              expectedGeneration == connectionGeneration else {
            return false
        }
        phase = .idle
        return true
    }

    func fail(_ attempt: Attempt) -> Bool {
        guard isCurrent(attempt) else { return false }
        phase = .failed(attempt)
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

    /// Cancels the active connection attempt and any owned dead-stream retry.
    func cancel() {
        task?.cancel()
        task = nil
        cancelDeadTerminalEventStreamRedial()
        phase = .idle
    }

    /// Claims the next barren-stream redial delay, coalescing while a delayed
    /// redial is already pending.
    func nextDeadTerminalEventStreamRedialDelay() -> Duration? {
        deadTerminalEventStreamRedialBackoff.nextRedialDelay()
    }

    /// Schedules one cancellable barren-stream retry under this recovery owner.
    /// The callback runs only if the owner generation is still current.
    /// - Parameters:
    ///   - delay: The injected-clock delay before retrying.
    ///   - clock: Clock used for the genuine retry deadline.
    ///   - operation: Main-actor recovery callback to invoke after the delay.
    func scheduleDeadTerminalEventStreamRedial(
        after delay: Duration,
        clock: any Clock<Duration>,
        operation: @escaping @MainActor () -> Void
    ) {
        let generation = UUID()
        deadTerminalEventStreamRedialGeneration = generation
        deadTerminalEventStreamRedialTask?.cancel()
        deadTerminalEventStreamRedialTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.deadTerminalEventStreamRedialGeneration == generation else {
                return
            }
            self.deadTerminalEventStreamRedialTask = nil
            self.deadTerminalEventStreamRedialBackoff.redialFired()
            operation()
        }
    }

    /// Cancels a pending barren-stream retry while preserving the accumulated
    /// session streak. Background suspension uses this form so a resumed
    /// session cannot immediately return to a tight redial loop.
    func cancelDeadTerminalEventStreamRedial() {
        deadTerminalEventStreamRedialGeneration = UUID()
        deadTerminalEventStreamRedialTask?.cancel()
        deadTerminalEventStreamRedialTask = nil
        deadTerminalEventStreamRedialBackoff.redialFired()
    }

    /// Resets the barren-stream retry state at a fresh account/session boundary.
    func resetDeadTerminalEventStreamBackoff() {
        deadTerminalEventStreamRedialBackoff.reset()
        cancelDeadTerminalEventStreamRedial()
    }
}
