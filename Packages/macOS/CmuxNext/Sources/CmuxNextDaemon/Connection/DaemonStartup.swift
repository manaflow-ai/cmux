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
public enum DaemonStartup {
    /// Retry delays; the last one repeats.
    public static let defaultDelays: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(5)]
    /// How long the window shows "connecting" before it shows the failure.
    public static let defaultDeadline: Duration = .seconds(10)

    /// Errors no retry can fix: the binary or daemon is wrong.
    public static func isPermanent(_ error: DaemonError) -> Bool {
        switch error {
        case .binaryNotFound, .wrongApp, .unsupportedProtocol, .missingCapabilities, .invalidSessionName: true
        default: false
        }
    }

    /// Makes a fresh connection per attempt and starts it until one
    /// succeeds. Calls `onFailure` after each failed attempt (the failed
    /// connection is already closed). Returns nil when the task is cancelled
    /// or the failure is permanent.
    public static func connect(
        delays: [Duration] = defaultDelays,
        clock: any Clock<Duration> = ContinuousClock(),
        makeConnection: @Sendable () -> DaemonConnection,
        onFailure: @Sendable (DaemonError) async -> Void
    ) async -> (DaemonConnection, DaemonIdentity)? {
        var attempt = 0
        while !Task.isCancelled {
            let connection = makeConnection()
            do {
                let identity = try await connection.start()
                return (connection, identity)
            } catch {
                await connection.close()
                if Task.isCancelled { return nil }
                let failure = (error as? DaemonError) ?? .launchFailed(String(describing: error))
                await onFailure(failure)
                if isPermanent(failure) { return nil }
            }
            if !delays.isEmpty {
                do { try await clock.sleep(for: delays[min(attempt, delays.count - 1)]) } catch { return nil }
            }
            attempt += 1
        }
        return nil
    }
}
