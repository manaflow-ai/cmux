import Foundation
public import CmuxNextWakeups

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
    /// The local session owner is alive and busy before it accepts clients: it restores the
    /// session or runs a long startup job (`server ensure` progress lines, the owner's
    /// `long-jobs.json`, or a parked `identify` on its live socket). Carries the jobs it named,
    /// empty when it named none (an older daemon). Not a failure: the window shows the jobs and
    /// says to wait, and nothing tells the person to quit (plans/cmux-next/long-jobs-DESIGN.md).
    case restoring([LongJob])

    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    public var isRestoring: Bool {
        if case .restoring = self { return true }
        return false
    }

    /// The jobs the restoring owner named (empty in every other state).
    public var restoringJobs: [LongJob] {
        if case .restoring(let jobs) = self { return jobs }
        return []
    }

    /// Whether a failed connect attempt marks the store failed now (`DaemonStore.markFailed`). A launch's
    /// first attempts fail while the daemon (or this Mac's Chief owner) still starts, and a failed store
    /// read "Unreachable" and "offline" on every launch: while connecting only a failure no retry can fix
    /// shows (`DaemonStartup.isPermanent`, or `retries` false: no attempt follows). Past the deadline
    /// (`DaemonService` marks the last failure then) or after a connection was up, every failure shows.
    /// A parked `identify` on the live local owner (``DaemonError/ownerRestoring(_:)``) never shows: the owner is alive
    /// and the window shows its jobs instead. While restoring, only a failure no retry can fix shows at once.
    public func showsFailure(_ error: DaemonError, retries: Bool) -> Bool {
        if retries, case .ownerRestoring = error { return false }
        if isRestoring { return !retries || DaemonStartup.shared.isPermanent(error) }
        return self != .connecting || !retries || DaemonStartup.shared.isPermanent(error)
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

    /// The session owner is alive and still restoring (`server.restore_timeout`).
    /// Such a failure does not spend the timed retry budget: the next `server
    /// ensure` waits for that owner again (the daemon bounds each wait), and
    /// past the budget the loop would wait for an event only, while a restore
    /// that ends behind the same socket fires none, so a page stayed "not
    /// connected" next to a ready daemon (cx-4bd8m).
    /// A parked `identify` on the live local owner (``DaemonError/ownerRestoring(_:)``) is the same: the owner is
    /// alive and busy, so the next attempt waits for it again (the incident of 2026-11-02, long-jobs-DESIGN.md).
    public func ownerIsRestoring(_ error: DaemonError) -> Bool {
        switch error {
        case .sessionRestoreTimedOut, .ownerRestoring: true
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
                if ownerIsRestoring(failure) { pacer.reset() }
                if failure.isBusyRefusal { pacer.refusedBusy() }
                guard await pacer.waitAfterFailure(wake: wake, clock: clock) else { return nil }
            }
        }
        // wakeup-allow: each iteration waits in RetryPacer (capped backoff, then events only, or the cap with `keepsTrying`)
        while !Task.isCancelled {
            let connection = makeConnection()
            // The tuple is built after the do/catch: Swift -O drops tuple elements returned
            // from an awaiting do (swiftlang/swift#92698, cx-21wc5).
            var identity: DaemonIdentity?
            do {
                DaemonLaunchTimings.shared.mark("daemon.connect_start")
                // The service owns this startup task. If teardown cancels it before the
                // connection is adopted, close the attempt so its endpoint provider cannot
                // keep launching a daemon after shutdown has joined the service task.
                identity = try await withTaskCancellationHandler {
                    try await connection.start()
                } onCancel: {
                    // concurrency-allow: cancellation cleanup is actor-isolated and joined by closeAndWait.
                    Task { await connection.close() }
                }
                DaemonLaunchTimings.shared.mark("daemon.handshake_end")
            } catch {
                await connection.closeAndWait()
                if Task.isCancelled { return nil }
                let failure = (error as? DaemonError) ?? .launchFailed(String(describing: error))
                await onFailure(failure)
                if isPermanent(failure) { return nil }
                if ownerIsRestoring(failure) { pacer.reset() }
                if failure.isBusyRefusal { pacer.refusedBusy() }
            }
            if let identity { return (connection, identity) }
            guard await pacer.waitAfterFailure(wake: wake, clock: clock) else { return nil }
        }
        return nil
    }
}
