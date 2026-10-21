import Foundation

/// What a confirmed restart did.
public nonisolated enum ServerRestartOutcome: Sendable, Equatable {
    /// The new server serves what was missing; `gained` are the named features it turned on.
    case restarted(gained: [ServerFeature])
    /// The server came back still without these capabilities (an external or pinned binary).
    case stillMissing([String])
    /// The restart failed; the message is for the toast.
    case failed(String)
}

extension ServerRestartOutcome {
    /// The toast after the restart, naming the server as `serverLabel`.
    public func message(serverLabel: String) -> String {
        switch self {
        case .restarted(let gained) where gained.isEmpty:
            UpdaterStrings.format("server.result.restartedPlain", "%@ restarted.", serverLabel)
        case .restarted:
            UpdaterStrings.format("server.result.restarted", "%@ restarted. The new features are on.", serverLabel)
        case .stillMissing:
            UpdaterStrings.format("server.result.stillMissing",
                                  "%@ restarted but still lacks the new features. It may run from another install.", serverLabel)
        case .failed(let reason):
            UpdaterStrings.format("server.result.failed", "Couldn't restart %1$@: %2$@", serverLabel, reason)
        }
    }
}
