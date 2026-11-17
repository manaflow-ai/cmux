import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemonService
import Foundation

/// Push on send: when the person sends to a Cloud chat whose folder came from this Mac (Move to Cloud, or a
/// Cloud start that copied a folder: ``CloudMovedChats``), the files changed here since the last push reach the
/// machine before the agent's turn starts (`cmux link sync on-send`, cmux-tui `link/sync_cli.rs`). Bounded: the
/// CLI waits 3 s at most and finishes behind in its own process; when the files are still arriving, the agent gets
/// a hidden note saying so (acpmux's prompt context). The send never waits longer, and never fails for it.
enum CloudPushOnSend {
    /// The wire's ``RemoteAcpmuxWire/BeforeSend`` for a chat on `daemon` (a Cloud machine), whose tab record is
    /// under one of `hosts` (its own host and the daemon's `registry:` host, as the ledger keys it).
    static func beforeSend(services: AppServices, daemon: DaemonService, hosts: [String]) -> RemoteAcpmuxWire.BeforeSend {
        { [weak services, weak daemon] session in
            guard let target = await target(services: services, daemon: daemon, hosts: hosts, session: session) else { return nil }
            return await target.cli.syncOnSend(socket: target.socket, local: target.local, remote: target.remote)
        }
    }

    /// The push this send makes, or nil: the chat came from no folder on this Mac (or went back to it), the app
    /// has no CLI, or the machine's link is down (the send goes as it is).
    @MainActor
    private static func target(services: AppServices?, daemon: DaemonService?, hosts: [String], session: String) async
        -> (cli: CloudMoveCLI, socket: String, local: String, remote: String)? {
        guard !session.isEmpty, let services, let daemon, let binary = services.cloud.move.cli,
              let entry = hosts.lazy.compactMap({ services.cloud.movedChats.entry(host: $0, session: session) }).first,
              entry.broughtBack == nil, !entry.localRoot.isEmpty, !entry.remoteFolder.isEmpty,
              let socket = await daemon.connection?.endpoint?.socketPath else { return nil }
        return (CloudMoveCLI(binary: binary), socket, entry.localRoot, entry.remoteFolder)
    }
}
