import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextUpdater
import Foundation

/// Restarts a server for the server-update prompt. Today: this app's local cmux-tui, by a
/// handoff that keeps every terminal. acpmux and remote hosts come next
/// (plans/cmux-next/server-updates-DESIGN.md steps 4 and 5).
@MainActor
final class AppServerRestarter: ServerRestarting {
    enum Failure: Error, CustomStringConvertible {
        case unsupported(ServerKind, ServerHost)
        case noSuccessor

        var description: String {
            switch self {
            case .unsupported(let kind, let host): "\(kind.displayName) on \(host.key) can't be restarted from here yet"
            case .noSuccessor: "the new server didn't connect"
            }
        }
    }

    private let daemon: DaemonService

    init(daemon: DaemonService) {
        self.daemon = daemon
    }

    func restart(_ kind: ServerKind, host: ServerHost) async throws -> ServerHandshake {
        guard kind == .cmuxTUI, host == .local else { throw Failure.unsupported(kind, host) }
        guard let identity = await daemon.restartForUpdate() else { throw Failure.noSuccessor }
        return ServerHandshake(daemon: identity, host: .local)
    }
}
