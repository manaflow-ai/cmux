import Foundation

/// The launch's read of the saved window records (#26681). A daemon still starting (a large
/// registry, journal maintenance after an update relaunch) can answer later than the 2 s
/// control-plane deadline; before, that failure read as "nothing saved": the launch window took
/// every workspace, and its first save replaced the stored windows with that one window. The read
/// waits up to `attemptTimeout` per request, continuing until the daemon answers or the launch
/// is cancelled. A reconnect waits for readiness rather than consuming a fixed retry budget.
public struct SavedWindowsRead: Sendable {
    public enum Outcome: Sendable {
        case loaded(WindowStateDocument)
        /// The stored records could not be read: they may hold windows, so nothing may replace them.
        case unread(any Error)
    }

    public var attempts: Int?
    public var attemptTimeout: Duration

    /// A finite `attempts` bounds a diagnostic read; launch restoration has no total deadline.
    public init(attempts: Int? = nil, attemptTimeout: Duration = .seconds(10)) {
        self.attempts = attempts
        self.attemptTimeout = attemptTimeout
    }

    /// Runs `load` on the caller's actor. `waitUntilReady` suspends on connection events before
    /// each attempt, including after a disconnect; without it only timed-out requests retry.
    public func run(isolation: isolated (any Actor)? = #isolation,
                    waitUntilReady: (() async throws -> Void)? = nil,
                    _ load: (Duration) async throws -> WindowStateDocument) async -> Outcome {
        var failure: any Error = DaemonError.notConnected
        var count = 0
        // wakeup-allow: launch-only retry; each attempt suspends for connection readiness or the request deadline; cancelled on quit
        while attempts.map({ count < max(1, $0) }) ?? true {
            do {
                try Task.checkCancellation()
                try await waitUntilReady?()
                try Task.checkCancellation()
                count += 1
                let document = try await load(attemptTimeout)
                try Task.checkCancellation()
                return .loaded(document)
            } catch {
                failure = error
                guard Self.isTransient(error) || (waitUntilReady != nil && (error as? DaemonError)?.isLostConnection == true) else { break }
            }
        }
        return .unread(failure)
    }

    /// A failure another attempt can get past: the daemon answered late. A connection that is not
    /// ready fails at once, so retrying it at once could not help.
    public static func isTransient(_ error: any Error) -> Bool {
        if case .timedOut = error as? DaemonError { return true }
        return false
    }
}
