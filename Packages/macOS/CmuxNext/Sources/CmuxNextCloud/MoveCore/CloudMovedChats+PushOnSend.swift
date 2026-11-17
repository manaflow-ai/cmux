public import Foundation

/// Push on send: when the person sends to a Cloud chat whose folder came from this Mac (Move to Cloud, or a Cloud
/// start that copied a folder), the files changed here since the last push reach the machine before the agent's
/// turn starts (`cmux link sync on-send`, cmux-tui `link/sync_cli/changed.rs`). Bounded: the CLI waits 3 s at most
/// and finishes behind in its own process; when the files are still arriving, the agent gets a hidden note saying
/// so (acpmux's prompt context). The send never waits longer, and never fails for it.
extension CloudMovedChats {
    /// The hook a chat's wire runs before each send (`RemoteAcpmuxWire.BeforeSend`): the note for the agent, or
    /// nil. `hosts` are the tab record's hosts the ledger may key the chat by (its own and the daemon's
    /// `registry:` host); `binary` is the app's cmux CLI and `socket` the machine link's socket, both read at the
    /// send (nil: no CLI, or the link is down, and the send goes as it is).
    public func pushOnSend(hosts: [String], binary: @escaping @MainActor @Sendable () -> URL?,
                           socket: @escaping @MainActor @Sendable () async -> String?)
        -> @Sendable (_ session: String) async -> String? {
        { [weak self] session in
            guard !session.isEmpty, let target = await self?.pushTarget(hosts: hosts, session: session, binary: binary),
                  let socket = await socket() else { return nil }
            return await target.cli.syncOnSend(socket: socket, local: target.local, remote: target.remote)
        }
    }

    /// The push a send to `session` makes, or nil: the chat came from no folder on this Mac (or went back to it),
    /// or the app has no CLI.
    private func pushTarget(hosts: [String], session: String, binary: @MainActor () -> URL?)
        -> (cli: CloudMoveCLI, local: String, remote: String)? {
        guard let binary = binary(),
              let entry = hosts.lazy.compactMap({ self.entry(host: $0, session: session) }).first,
              entry.broughtBack == nil, !entry.localRoot.isEmpty, !entry.remoteFolder.isEmpty else { return nil }
        return (CloudMoveCLI(binary: binary), entry.localRoot, entry.remoteFolder)
    }
}
