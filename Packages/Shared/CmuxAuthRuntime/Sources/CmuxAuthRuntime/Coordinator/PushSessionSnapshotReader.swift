/// A bounded ``TokenProviding/authenticatedSessionSnapshot()`` read for push
/// registration (CmuxPushRegistration, which the classic iPhone app links): the
/// push phases' deadline, their 30 s timed-out lease and redacted timeout logs.
/// Keep one reader per push service; its timed-out lease is the reader's own.
public struct PushSessionSnapshotReader: Sendable {
    public enum Phase: Sendable {
        case registration
        case unregistration
    }

    private let timeout: Duration
    private let clock: any Clock<Duration>
    private let registry = AuthPhaseTimeoutRegistry()
    private let log = AuthDebugLog()

    public init(timeout: Duration, clock: any Clock<Duration>) {
        self.timeout = timeout
        self.clock = clock
    }

    /// - Throws: ``AuthError/timedOut`` at the deadline or while an earlier
    ///   timed-out read of the same phase still runs; otherwise the provider's error.
    public func snapshot(
        _ phase: Phase,
        from tokenProvider: any TokenProviding
    ) async throws -> AuthenticatedSessionSnapshot {
        try await withAuthPhaseTimeout(
            phase == .registration ? .pushRegistrationSession : .pushUnregistrationSession,
            duration: timeout,
            clock: clock,
            log: log,
            registry: registry,
            blocksRetriesWhileTimedOutOperationActive: true
        ) {
            // This provider API only reads a coherent stored token pair or
            // awaits bounded launch bootstrap. Cancelling it cannot leave
            // an ambiguous server mutation behind.
            try await tokenProvider.authenticatedSessionSnapshot()
        }
    }
}
