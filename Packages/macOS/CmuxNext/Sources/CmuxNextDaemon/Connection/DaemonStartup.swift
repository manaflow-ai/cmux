import Foundation

/// How the first connection to a daemon is going, for the window's
/// connecting state and the control socket's errors.
public enum DaemonStartupState: Sendable, Equatable {
    /// Still trying, within the startup deadline.
    case connecting
    /// Connected at least once; later drops are the connection's own
    /// reconnect loop (`DaemonStore.connectionState`).
    case connected
    /// The deadline passed without a connection, or the daemon is
    /// incompatible. Carries the last failure. Retrying continues unless
    /// `isPermanent`.
    case unavailable(DaemonError)

    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// First connect with retry. `DaemonConnection.start()` tries once; after
/// that the connection reconnects by itself. Without this loop one failed
/// first attempt (a slow `server ensure`, a rival owner holding the session
/// lock, a daemon busy with a dead client's request) left the app with no
/// connection for good.
///
/// Attempts are spaced by `policy`'s capped backoff; once its timed budget
/// is spent no timer runs and the loop waits for `wake` (app activation,
/// network change, the socket appearing). It never re-spawns `server
/// ensure` on a fixed period.
public struct DaemonStartup: Sendable {
    public static let shared = Self()
    /// How the window shows "connecting" before it shows the failure.
    public let defaultDeadline: Duration = .seconds(10)

    /// Errors no retry can fix: the binary or daemon is wrong.
    public func isPermanent(_ error: DaemonError) -> Bool {
        switch error {
        case .binaryNotFound, .wrongApp, .unsupportedProtocol, .missingCapabilities, .invalidSessionName, .endpointBlocked: true
        default: false
        }
    }

    /// Makes a fresh connection per attempt and starts it until one
    /// succeeds. Calls `onFailure` after each failed attempt (the failed
    /// connection is already closed). Returns nil when the task is cancelled
    /// or the failure is permanent.
    ///
    /// `first`, when given, is the first attempt's outcome (an attempt
    /// already running, `DaemonPrestart`); `makeConnection` makes the rest.
    public func connect(
        policy: RetryPolicy = .firstConnect,
        wake: RetryWake = RetryWake(owner: "DaemonStartup"),
        clock: any Clock<Duration> = ContinuousClock(),
        first: (@Sendable () async -> DaemonPrestart.Outcome)? = nil,
        makeConnection: @Sendable () -> DaemonConnection,
        onFailure: @Sendable (DaemonError) async -> Void
    ) async -> (DaemonConnection, DaemonIdentity)? {
        var pacer = RetryPacer(policy)
        if let first {
            switch await first() {
            case .success(let connected):
                return connected
            case .failure(let failure):
                if Task.isCancelled { return nil }
                await onFailure(failure)
                if isPermanent(failure) { return nil }
                guard await pacer.waitAfterFailure(wake: wake, clock: clock) else { return nil }
            }
        }
        // wakeup-allow: each iteration waits in RetryPacer (capped backoff, then events only)
        while !Task.isCancelled {
            let connection = makeConnection()
            do {
                DaemonLaunchTimings.shared.mark("daemon.connect_start")
                let identity = try await connection.start()
                DaemonLaunchTimings.shared.mark("daemon.handshake_end")
                return (connection, identity)
            } catch {
                await connection.close()
                if Task.isCancelled { return nil }
                let failure = (error as? DaemonError) ?? .launchFailed(String(describing: error))
                await onFailure(failure)
                if isPermanent(failure) { return nil }
            }
            guard await pacer.waitAfterFailure(wake: wake, clock: clock) else { return nil }
        }
        return nil
    }
}
