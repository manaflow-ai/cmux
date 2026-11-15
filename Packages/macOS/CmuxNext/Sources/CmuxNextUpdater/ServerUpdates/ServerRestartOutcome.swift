public import CmuxNextDesign
import Foundation

/// What a confirmed restart did.
public nonisolated enum ServerRestartOutcome: Sendable, Equatable {
    /// The new server serves what was missing; `gained` are the named features it turned on.
    case restarted(gained: [ServerFeature])
    /// The server came back still without these capabilities (an external or pinned binary).
    case stillMissing([String])
    /// The restart failed; the reason is for the log, never the toast.
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
        case .failed:
            UpdaterStrings.format("server.result.failed", "Couldn't restart %@. Try again.", serverLabel)
        }
    }

    /// The result toast's one action: Try Again after a failure; none otherwise.
    public var retryTitle: String? {
        guard case .failed = self else { return nil }
        return UpdaterStrings.retry
    }

    /// The result toast (`id`), naming the server as `serverLabel`, with ``retryTitle`` as its action.
    public func toast(id: String, serverLabel: String) -> CmuxToast {
        CmuxToast(id: id, message: message(serverLabel: serverLabel), action: retryTitle.map { CmuxToast.Action(title: $0) })
    }
}
