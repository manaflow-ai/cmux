public import CmuxSettings

/// An opaque handle to the live tab-manager a listener start binds to.
///
/// The control-socket listener must be started against the app's per-window tab
/// manager, an app-target type that cannot cross the package boundary. The app
/// conforms its tab manager to this marker so ``SocketListenerLifecycleCoordinator``
/// can thread a caller-supplied or host-resolved tab manager through the start
/// path without naming the concrete type.
public protocol SocketListenerStartTarget: AnyObject {}

/// The irreducible live-state operations the socket-listener lifecycle needs
/// from the app target.
///
/// ``SocketListenerLifecycleCoordinator`` owns the policy (configuration
/// resolution, start/ensure/restart sequencing, sudden-termination latch, and
/// telemetry assembly). The concrete listener it drives — the live
/// `TerminalController` socket server plus the AppKit tab-manager resolution —
/// stays in the composition root and is reached only through this seam. Every
/// member is `@MainActor` because every lifecycle mutator originates on the main
/// actor, except the two pure reads that the legacy code performed
/// `nonisolated`.
@MainActor
public protocol SocketListenerLifecycleHost: AnyObject {
    /// Whether a startup listener may reclaim `path` (delegates to the socket
    /// transport's path-lock probe). Matches the legacy
    /// `socketTransport.pathCanBeReclaimedForStartup` method reference passed to
    /// ``SocketControlSettings/initialSocketPathBeforeListenerStart(preferredPath:bundleIdentifier:isDebugBuild:currentUserID:probeStableDefaultPathEntry:stableDefaultSocketCanBeReclaimed:)``.
    nonisolated func startupPathCanBeReclaimed(_ path: String) -> Bool

    /// Reserves `path` as the startup socket path on the live listener before it
    /// starts accepting.
    func reserveStartupSocketPath(_ path: String)

    /// The path the live listener is actually using, given a preferred path.
    nonisolated func activeSocketPath(preferredPath: String) -> String

    /// A point-in-time health snapshot of the live listener for `expectedSocketPath`.
    nonisolated func listenerHealth(expectedSocketPath: String) -> SocketListenerHealth

    /// Resolves the tab manager a restart should bind to (the app's current
    /// active or first-registered main window), or `nil` when none exists.
    func resolveRestartTarget() -> (any SocketListenerStartTarget)?

    /// Starts the live listener against `target` at `socketPath` with `mode`.
    func startListener(
        target: any SocketListenerStartTarget,
        socketPath: String,
        mode: SocketControlMode
    )

    /// Stops the live listener. Synchronous by contract: termination needs the
    /// socket unlinked before exit.
    func stopListener()

    /// Records a telemetry breadcrumb in the `socket` category with stringly
    /// payload values, matching the legacy `sentryBreadcrumb` calls.
    func recordBreadcrumb(_ message: String, data: [String: String])
}
