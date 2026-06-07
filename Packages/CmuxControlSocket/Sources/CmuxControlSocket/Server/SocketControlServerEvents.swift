public import Darwin

/// Callback seam between ``SocketControlServer`` and its host application.
///
/// The server is a transport/state-machine component: it owns the listener
/// socket, the accept source, and the recovery state, but it never performs
/// telemetry, command dispatch, or app-level restart scheduling itself. Each
/// of those crosses this seam as a `@Sendable` closure the composition root
/// injects at construction.
///
/// Threading: closures are invoked synchronously from whatever context drives
/// the server — the caller of ``SocketControlServer/start(socketPath:accessMode:preserveAcceptFailureStreak:)``
/// for startup events, the internal listener queue for accept/path-monitor
/// events. Implementations must be safe to call from any thread and must not
/// block.
public struct SocketControlServerEvents: Sendable {
    /// Emits a non-fatal telemetry breadcrumb (`sentryBreadcrumb` in the app).
    public var breadcrumb: @Sendable (_ message: String, _ data: [String: any Sendable]) -> Void

    /// Reports a listener failure. The host decides whether to escalate the
    /// breadcrumb to a captured error (the app applies a per-key cooldown).
    /// `data` already contains the listener-state snapshot fields plus
    /// `stage`/`errno` entries; `stage` and `errnoCode` are passed discretely
    /// so the host can build its dedupe key without re-parsing the dictionary.
    public var failure: @Sendable (
        _ message: String,
        _ stage: String,
        _ errnoCode: Int32?,
        _ data: [String: any Sendable]
    ) -> Void

    /// The listener committed to running state and is about to arm the path
    /// monitor and accept source. Invoked at the exact point the legacy
    /// implementation posted `.socketListenerDidStart` (synchronously inside
    /// `start`, on the caller's thread — the main thread on every current
    /// start path).
    public var listenerDidStart: @Sendable (_ path: String, _ generation: UInt64) -> Void

    /// Records the bound socket path to the build-variant marker files.
    /// Invoked after `listen(2)` succeeds, before the running-state commit.
    public var recordLastSocketPath: @Sendable (_ path: String) -> Void

    /// A client connection was accepted and configured. Ownership of the
    /// descriptor transfers to the host, which must eventually `close(2)` it.
    /// `peerPid` is captured via `LOCAL_PEERPID` before short-lived clients
    /// can disconnect; `nil` when the lookup failed.
    public var clientAccepted: @Sendable (_ socket: Int32, _ peerPid: pid_t?) -> Void

    /// The path monitor observed that the bound socket path no longer exists
    /// (validated against the bound identity under the state lock). The host
    /// should hop to its restart context, re-validate with
    /// ``SocketControlServer/shouldRestartForMissingPath(path:generation:)``,
    /// and stop/start the listener.
    public var pathMissingDetected: @Sendable (_ path: String, _ generation: UInt64) -> Void

    /// Accept failures crossed the rearm threshold; the listener tore itself
    /// down and parked a pending rearm generation. The host should wait
    /// `delayMs`, then call
    /// ``SocketControlServer/claimPendingRearm(generation:errnoCode:consecutiveFailures:delayMs:)``
    /// and, on a non-`nil` path, restart the listener preserving the failure
    /// streak.
    public var rearmRequested: @Sendable (
        _ generation: UInt64,
        _ errnoCode: Int32,
        _ consecutiveFailures: Int,
        _ delayMs: Int
    ) -> Void

    /// Creates the event seam.
    /// - Parameters:
    ///   - breadcrumb: Non-fatal telemetry sink.
    ///   - failure: Listener-failure sink (breadcrumb + optional capture).
    ///   - listenerDidStart: Listener-started notification hook.
    ///   - recordLastSocketPath: Bound-path marker writer.
    ///   - clientAccepted: Accepted-client hand-off; receiver owns the fd.
    ///   - pathMissingDetected: Socket-path-deleted restart trigger.
    ///   - rearmRequested: Accept-failure rearm scheduler.
    public init(
        breadcrumb: @escaping @Sendable (String, [String: any Sendable]) -> Void,
        failure: @escaping @Sendable (String, String, Int32?, [String: any Sendable]) -> Void,
        listenerDidStart: @escaping @Sendable (String, UInt64) -> Void,
        recordLastSocketPath: @escaping @Sendable (String) -> Void,
        clientAccepted: @escaping @Sendable (Int32, pid_t?) -> Void,
        pathMissingDetected: @escaping @Sendable (String, UInt64) -> Void,
        rearmRequested: @escaping @Sendable (UInt64, Int32, Int, Int) -> Void
    ) {
        self.breadcrumb = breadcrumb
        self.failure = failure
        self.listenerDidStart = listenerDidStart
        self.recordLastSocketPath = recordLastSocketPath
        self.clientAccepted = clientAccepted
        self.pathMissingDetected = pathMissingDetected
        self.rearmRequested = rearmRequested
    }
}
