import Foundation

/// What the app does with a running daemon of another build after an update
/// (plans/cmux-next/durable-sessions.md section 3).
public enum DaemonVersionDecision: Sendable, Equatable {
    /// Keep the running daemon; the reason is for the log.
    case keep(String)
    /// Hand off: the running daemon (`running` commit) exits, keeping its
    /// terminal hosts, and a daemon of the bundled build (`bundled`) adopts them.
    case restart(running: String, bundled: String)
}

extension DaemonLauncher {
    static func versionDecision(running: String?, bundled: String?) -> DaemonVersionDecision {
        .keep("not implemented")
    }

    /// After an update the app finds the daemon an older app started: hand
    /// it off to the bundled build. Not implemented yet: the app never moves
    /// onto the new daemon build.
    public func handOffIfStale(identity: DaemonIdentity, using connection: DaemonConnection,
                               bundledCommit: String? = nil) async -> DaemonVersionDecision {
        .keep("not implemented")
    }
}
