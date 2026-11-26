/// Clock seam for this package's delayed work (the proxy broker's restart
/// backoff, the CLI relay's minimum auth-failure delay, and the PTY bridge's
/// handshake/unused-bridge timeouts), so tests can drive delays with virtual
/// time instead of waiting on the wall clock.
///
/// Mirrors the `SocketRecoveryClock` precedent in CmuxControlSocket: one
/// narrow sleep entry point, injected through initializers, defaulting to the
/// continuous clock in production.
public protocol RemoteProxyRetryClock: Sendable {
    /// Suspends the calling task for `milliseconds`, throwing
    /// `CancellationError` when the task is cancelled first.
    func sleep(forMilliseconds milliseconds: Int) async throws
}

/// Production ``RemoteProxyRetryClock`` backed by `ContinuousClock`.
public struct SystemRemoteProxyRetryClock: RemoteProxyRetryClock {
    /// Creates the system clock.
    public init() {}

    /// Sleeps on the continuous clock; cancellation propagates as
    /// `CancellationError`.
    public func sleep(forMilliseconds milliseconds: Int) async throws {
        try await ContinuousClock().sleep(for: .milliseconds(milliseconds))
    }
}
