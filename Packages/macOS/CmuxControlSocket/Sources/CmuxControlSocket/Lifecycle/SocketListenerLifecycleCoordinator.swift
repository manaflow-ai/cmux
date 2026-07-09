import CmuxSettings
import Foundation

/// Owns the control-socket listener lifecycle policy, draining it out of the app
/// delegate.
///
/// This coordinator resolves the listener configuration from
/// ``SocketControlSettings``, sequences the reserve / start / ensure / restart
/// flows, assembles their telemetry, and holds the sudden-termination latch. The
/// live listener and the app's tab-manager resolution stay in the composition
/// root behind ``SocketListenerLifecycleHost``; the coordinator never names an
/// app-target type.
///
/// ## Isolation
/// `@MainActor` because every lifecycle mutator (startup reservation ordering,
/// the synchronous termination unlink, restart on wake) originates on the main
/// actor in the app delegate. Co-locating this policy with its callers keeps the
/// bridging to the live listener as plain main-actor calls — the same ruling
/// that shaped ``SocketControlServer``. The two pure listener reads
/// (`activeSocketPath`, `listenerHealth`) the legacy code performed off-actor
/// remain `nonisolated` on the host seam.
@MainActor
public final class SocketListenerLifecycleCoordinator {
    private let host: any SocketListenerLifecycleHost
    private var didDisableSuddenTermination = false

    /// Creates the lifecycle coordinator.
    ///
    /// - Parameter host: The composition-root seam vending the live listener
    ///   operations and tab-manager resolution.
    public init(host: any SocketListenerLifecycleHost) {
        self.host = host
    }

    /// The resolved listener configuration when the socket is enabled, or `nil`
    /// when the effective mode is ``SocketControlMode/off``.
    ///
    /// Reads the user mode from `UserDefaults.standard` under
    /// ``SocketControlSettings/appStorageKey``, migrates and resolves it through
    /// ``SocketControlSettings/effectiveMode(userMode:)``, then pairs it with
    /// ``SocketControlSettings/socketPath(bundleIdentifier:isDebugBuild:)``.
    public func configurationIfEnabled() -> SocketListenerConfiguration? {
        let raw = UserDefaults.standard.string(forKey: SocketControlSettings.appStorageKey)
            ?? SocketControlSettings.defaultMode.rawValue
        let userMode = SocketControlSettings.migrateMode(raw)
        let mode = SocketControlSettings.effectiveMode(userMode: userMode)
        guard mode != .off else { return nil }
        return SocketListenerConfiguration(mode: mode, path: SocketControlSettings.socketPath())
    }

    /// Reserves the startup socket path on the live listener before it accepts,
    /// when the socket is enabled.
    public func reserveInitialSocketPathIfNeeded() {
        guard let config = configurationIfEnabled() else { return }
        let startupPath = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: config.path,
            stableDefaultSocketCanBeReclaimed: host.startupPathCanBeReclaimed
        )
        host.reserveStartupSocketPath(startupPath)
    }

    /// Starts the listener against `target` when the socket is enabled, otherwise
    /// stops it.
    ///
    /// - Parameters:
    ///   - target: The tab manager the start binds to (the caller's explicit
    ///     window tab manager).
    ///   - source: A telemetry source tag for the start breadcrumb.
    public func start(target: any SocketListenerStartTarget, source: String) {
        guard let config = configurationIfEnabled() else {
            host.stopListener()
            return
        }
        let path = host.activeSocketPath(preferredPath: config.path)
        host.recordBreadcrumb("socket.listener.start", data: [
            "mode": config.mode.rawValue,
            "path": path,
            "source": source
        ])
        host.startListener(target: target, socketPath: path, mode: config.mode)
    }

    /// Ensures a healthy listener against `target` when the socket is enabled,
    /// restarting it only when an unhealthy signal is detected; stops it when the
    /// socket is disabled.
    ///
    /// - Parameters:
    ///   - target: The tab manager an (re)start binds to.
    ///   - source: A telemetry source tag for the ensure breadcrumb.
    public func ensure(target: any SocketListenerStartTarget, source: String) {
        guard let config = configurationIfEnabled() else {
            host.stopListener()
            return
        }

        let path = host.activeSocketPath(preferredPath: config.path)
        let health = host.listenerHealth(expectedSocketPath: path)
        guard !health.isHealthy else { return }

        host.recordBreadcrumb("socket.listener.ensure", data: [
            "mode": config.mode.rawValue,
            "path": path,
            "source": source,
            "failureSignals": health.failureSignals.joined(separator: ",")
        ])
        host.startListener(target: target, socketPath: path, mode: config.mode)
    }

    /// Restarts the listener when the socket is enabled and a tab manager can be
    /// resolved.
    ///
    /// - Parameter source: A telemetry source tag for the restart breadcrumb.
    public func restart(source: String) {
        guard let target = host.resolveRestartTarget(),
              let config = configurationIfEnabled() else { return }
        let restartPath = host.activeSocketPath(preferredPath: config.path)
        host.recordBreadcrumb("socket.listener.restart", data: [
            "mode": config.mode.rawValue,
            "path": restartPath,
            "source": source
        ])
        host.stopListener()
        host.startListener(target: target, socketPath: restartPath, mode: config.mode)
    }

    /// Disables sudden termination once, latching so a later
    /// ``enableSuddenTerminationIfNeeded()`` can balance it.
    public func disableSuddenTerminationIfNeeded() {
        guard !didDisableSuddenTermination else { return }
        ProcessInfo.processInfo.disableSuddenTermination()
        didDisableSuddenTermination = true
    }

    /// Re-enables sudden termination only when it was previously disabled by
    /// ``disableSuddenTerminationIfNeeded()``.
    public func enableSuddenTerminationIfNeeded() {
        guard didDisableSuddenTermination else { return }
        ProcessInfo.processInfo.enableSuddenTermination()
        didDisableSuddenTermination = false
    }
}
