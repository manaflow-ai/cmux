import Foundation

/// Pairs an immediately recorded phase entry with its eventual completion.
///
/// The existing bounded diagnostic ingress handles delivery off the caller's
/// executor. A blocked operation therefore leaves its entry available without
/// waiting for that operation, the main actor, or a timeout task to finish.
public struct TerminalWorkInterval: Sendable {
    private let log: DiagnosticLog
    private let detail: TerminalWorkDiagnostic
    private let startedAt: UInt64

    init(log: DiagnosticLog, detail: TerminalWorkDiagnostic, startedAt: UInt64) {
        self.log = log
        self.detail = detail
        self.startedAt = startedAt
        log.record(DiagnosticEvent(code: .terminalWorkStarted, tNanos: startedAt, terminalWork: detail))
    }

    /// Records completion; call exactly once at the operation's return boundary.
    /// - Parameter now: Monotonic nanoseconds, injectable for deterministic tests.
    public func end(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let elapsed = now >= startedAt ? (now - startedAt) / 1_000_000 : 0
        log.record(DiagnosticEvent(
            code: .terminalWorkFinished,
            tNanos: now,
            ms: UInt32(clamping: elapsed),
            terminalWork: detail
        ))
    }
}
