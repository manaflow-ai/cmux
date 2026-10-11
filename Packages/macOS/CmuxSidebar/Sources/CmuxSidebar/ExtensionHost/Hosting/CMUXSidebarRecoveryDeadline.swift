/// Owns one cancellable lifecycle deadline, with an injected sleep operation.
@MainActor
@_spi(CmuxHostTransport) public final class CMUXSidebarRecoveryDeadline {
    private let sleep: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?

    /// Creates a deadline driven by the supplied clock operation.
    /// - Parameter sleep: Cancellable clock sleep; tests can advance it without wall time.
    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
        try await ContinuousClock().sleep(for: duration)
    }) {
        self.sleep = sleep
    }

    /// Replaces the previous deadline with one operation.
    /// - Parameters:
    ///   - delay: Maximum duration before the deadline expires.
    ///   - onExpire: Called once if the active deadline expires without cancellation.
    public func arm(after delay: Duration, onExpire: @escaping @MainActor () -> Void) {
        cancel()
        let sleep = self.sleep
        task = Task { @MainActor in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            onExpire()
        }
    }

    /// Cancels the active deadline before teardown or a lifecycle transition.
    public func cancel() {
        task?.cancel()
        task = nil
    }

    /// Waits for the currently armed operation in deterministic package tests.
    func waitForCurrentOperation() async { await task?.value }
}
