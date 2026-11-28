import Foundation

extension AuthCoordinator {
    /// Races an operation against its phase deadline on the injected clock.
    func runPhase<T: Sendable>(
        _ phase: AuthPhase,
        timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if phase == .validateSession {
            return try await runValidationPhase(timeout: timeout, operation)
        }
        if phase == .fetchUser || phase == .listTeams {
            return try await runTokenTouchingPhase(phase, timeout: timeout, operation)
        }
        return try await withAuthPhaseTimeout(
            phase,
            duration: timeout,
            clock: clock,
            log: log,
            registry: phaseTimeoutRegistry,
            blocksRetriesWhileTimedOutOperationActive: phase == .sendCode,
            operation: operation
        )
    }
}
