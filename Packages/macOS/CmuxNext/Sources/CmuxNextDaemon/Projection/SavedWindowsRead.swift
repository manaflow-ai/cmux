import Foundation

/// The launch's read of the saved window records (#26681). A daemon still starting (a large
/// registry, journal maintenance after an update relaunch) can answer later than the 2 s
/// control-plane deadline; before, that failure read as "nothing saved": the launch window took
/// every workspace, and its first save replaced the stored windows with that one window. The read
/// waits up to `attemptTimeout` and tries again after a timeout or a dropped connection; when it
/// still fails, the outcome says so, and the launch keeps the stored records unwritten.
public struct SavedWindowsRead: Sendable {
    public enum Outcome: Sendable {
        case loaded(WindowStateDocument)
        /// The stored records could not be read: they may hold windows, so nothing may replace them.
        case unread(any Error)
    }

    public var attempts: Int
    public var attemptTimeout: Duration

    public init(attempts: Int = 3, attemptTimeout: Duration = .seconds(10)) {
        self.attempts = attempts
        self.attemptTimeout = attemptTimeout
    }

    /// Runs `load` (one attempt's read with its deadline) on the caller's actor.
    public func run(isolation: isolated (any Actor)? = #isolation,
                    _ load: (Duration) async throws -> WindowStateDocument) async -> Outcome {
        var failure: any Error = DaemonError.notConnected
        // wakeup-allow: bounded retry (`attempts`), each attempt waits on the daemon's reply or its deadline
        for _ in 0 ..< max(1, attempts) {
            do {
                return .loaded(try await load(attemptTimeout))
            } catch {
                failure = error
                guard Self.isTransient(error) else { break }
            }
        }
        return .unread(failure)
    }

    /// A failure another attempt can get past: the daemon was slow or its connection dropped.
    public static func isTransient(_ error: any Error) -> Bool {
        switch error as? DaemonError {
        case .timedOut, .notConnected, .connectionClosed, .daemonShutdown: true
        default: false
        }
    }
}
