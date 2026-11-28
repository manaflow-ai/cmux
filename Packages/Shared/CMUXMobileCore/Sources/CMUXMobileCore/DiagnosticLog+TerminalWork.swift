import Foundation

extension DiagnosticLog {
    /// Records a phase before entering a potentially blocking terminal API.
    ///
    /// Use `defer { interval.end() }` for synchronous work. For queued work,
    /// capture the owner context before dispatch and begin the phase on the
    /// executor that actually calls the API. No terminal bytes, names, paths,
    /// coordinates, or persistent IDs can enter this schema.
    /// - Parameters:
    ///   - phase: The actual work boundary, not a guessed hang cause.
    ///   - context: An immutable snapshot of the originating owner.
    ///   - operationID: Ephemeral correlation, injectable for tests.
    ///   - now: Monotonic nanoseconds, injectable for tests.
    ///   - onMainThread: The current execution domain, injectable for tests.
    /// - Returns: An interval whose completion records the measured duration.
    public nonisolated func beginTerminalWork(
        _ phase: TerminalWorkDiagnostic.Phase,
        context: TerminalWorkContext = .init(),
        operationID: UUID = UUID(),
        at now: UInt64 = DispatchTime.now().uptimeNanoseconds,
        onMainThread: Bool = Thread.isMainThread
    ) -> TerminalWorkInterval {
        TerminalWorkInterval(
            log: self,
            detail: TerminalWorkDiagnostic(
                operationID: operationID, phase: phase, context: context, onMainThread: onMainThread
            ),
            startedAt: now
        )
    }
}
