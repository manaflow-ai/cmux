/// Callback seam between ``SocketControlServer`` and its host application.
///
/// The server is a transport/state-machine component: it owns the listener
/// socket, the accept source, and the recovery state, but it never performs
/// telemetry, command dispatch, or app-level restart scheduling itself. Each
/// of those crosses this seam as a `@Sendable` closure the composition root
/// injects at construction. Accepted client connections do not cross this
/// seam; they are delivered through ``SocketControlServer/connections``.
///
/// Threading: ``listenerDidStart`` is `@MainActor` and fires synchronously
/// inside `start()` (every lifecycle mutation runs on the main actor). The
/// remaining closures are invoked from the main actor (lifecycle and
/// recovery paths) or the listener queue (accept drain and path monitor);
/// they must be safe to call from any thread and must not block.
public struct SocketControlServerEvents: Sendable {
    /// Emits a non-fatal telemetry breadcrumb (`sentryBreadcrumb` in the app).
    public let breadcrumb: @Sendable (_ message: String, _ data: [String: any Sendable]) -> Void

    /// Reports a listener failure. The host decides whether to escalate the
    /// breadcrumb to a captured error (the app applies a per-key cooldown).
    /// `data` already contains the listener-state snapshot fields plus
    /// `stage`/`errno` entries; `stage` and `errnoCode` are passed discretely
    /// so the host can build its dedupe key without re-parsing the dictionary.
    public let failure: @Sendable (
        _ message: String,
        _ stage: String,
        _ errnoCode: Int32?,
        _ data: [String: any Sendable]
    ) -> Void

    /// The listener committed to running state and is about to arm the path
    /// monitor and accept source. Invoked synchronously inside `start()` on
    /// the main actor, at the same lifecycle point the legacy implementation
    /// posted `.socketListenerDidStart`.
    public let listenerDidStart: @MainActor @Sendable (_ path: String, _ generation: UInt64) -> Void

    /// Records the bound socket path to the build-variant marker files.
    /// Invoked after `listen(2)` succeeds, before the running-state commit.
    public let recordLastSocketPath: @Sendable (_ path: String) -> Void

    /// The path monitor observed that the bound socket path no longer exists
    /// (validated against the published snapshot on the listener queue). The
    /// host should hop to its restart context, re-validate with
    /// ``SocketControlServer/shouldRestartForMissingPath(path:generation:)``,
    /// and stop/start the listener.
    public let pathMissingDetected: @Sendable (_ path: String, _ generation: UInt64) -> Void

    /// Accept failures crossed the rearm threshold; the listener tore itself
    /// down and parked a pending rearm generation. The host should wait
    /// `delayMs`, then call
    /// ``SocketControlServer/claimPendingRearm(generation:errnoCode:consecutiveFailures:delayMs:)``
    /// and, on a non-`nil` path, restart the listener preserving the failure
    /// streak.
    public let rearmRequested: @Sendable (
        _ generation: UInt64,
        _ errnoCode: Int32,
        _ consecutiveFailures: Int,
        _ delayMs: Int
    ) -> Void

    /// Creates the event seam.
    /// - Parameters:
    ///   - breadcrumb: Non-fatal telemetry sink.
    ///   - failure: Listener-failure sink (breadcrumb + optional capture).
    ///   - listenerDidStart: Listener-started notification hook (main actor).
    ///   - recordLastSocketPath: Bound-path marker writer.
    ///   - pathMissingDetected: Socket-path-deleted restart trigger.
    ///   - rearmRequested: Accept-failure rearm scheduler.
    public init(
        breadcrumb: @escaping @Sendable (String, [String: any Sendable]) -> Void,
        failure: @escaping @Sendable (String, String, Int32?, [String: any Sendable]) -> Void,
        listenerDidStart: @escaping @MainActor @Sendable (String, UInt64) -> Void,
        recordLastSocketPath: @escaping @Sendable (String) -> Void,
        pathMissingDetected: @escaping @Sendable (String, UInt64) -> Void,
        rearmRequested: @escaping @Sendable (UInt64, Int32, Int, Int) -> Void
    ) {
        self.breadcrumb = breadcrumb
        self.failure = failure
        self.listenerDidStart = listenerDidStart
        self.recordLastSocketPath = recordLastSocketPath
        self.pathMissingDetected = pathMissingDetected
        self.rearmRequested = rearmRequested
    }
}
