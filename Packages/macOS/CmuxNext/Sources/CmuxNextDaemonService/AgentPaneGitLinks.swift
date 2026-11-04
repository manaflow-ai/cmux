import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// One ``AgentPaneGitLink`` per machine. A chat tab's git reads go to the session
/// host of the machine that holds it, so a Cloud or SSH chat's Changes and file search read the
/// folder on that machine, never a folder of the same path on this Mac (cx-d0tq).
public final class AgentPaneGitLinks {
    /// This Mac's link.
    public let local: AgentPaneGitLink
    private let remoteDaemons: @MainActor () -> [DaemonService]
    private var remote: [ObjectIdentifier: AgentPaneGitLink] = [:]

    /// - Parameters:
    ///   - local: This Mac's daemon.
    ///   - remoteDaemons: The daemons of the other machines the app holds now (Cloud, SSH,
    ///     servers); a link of a machine no longer listed closes at the next ``link(for:)``.
    public init(local: DaemonService, remoteDaemons: @escaping @MainActor () -> [DaemonService]) {
        self.remoteDaemons = remoteDaemons
        self.local = AgentPaneGitLink(daemon: local)
    }

    /// The link of `daemon`'s machine, opened on first use. Links of machines that left the app
    /// (removed, signed out) close here.
    public func link(for daemon: DaemonService) -> AgentPaneGitLink {
        if daemon.isLocal { return local }
        let live = Set(remoteDaemons().map(ObjectIdentifier.init))
        for (id, link) in remote where !live.contains(id) {
            link.close()
            remote[id] = nil
        }
        if let link = remote[ObjectIdentifier(daemon)] { return link }
        let link = AgentPaneGitLink(daemon: daemon)
        remote[ObjectIdentifier(daemon)] = link
        return link
    }
}
