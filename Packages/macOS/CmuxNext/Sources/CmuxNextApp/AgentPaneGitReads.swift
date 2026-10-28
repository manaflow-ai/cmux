import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// One ``AgentPaneGitLink`` per machine. A chat tab's git reads go to the session
/// host of the machine that holds it, so a Cloud or SSH chat's Changes and file search read the
/// folder on that machine, never a folder of the same path on this Mac (cx-d0tq).
final class AgentPaneGitLinks {
    /// This Mac's link.
    let local: AgentPaneGitLink
    private let machines: MachineRegistry
    private var remote: [ObjectIdentifier: AgentPaneGitLink] = [:]

    init(machines: MachineRegistry) {
        self.machines = machines
        local = AgentPaneGitLink(daemon: machines.local)
    }

    /// The link of `daemon`'s machine, opened on first use. Links of machines that left the app
    /// (removed, signed out) close here.
    func link(for daemon: DaemonService) -> AgentPaneGitLink {
        if daemon.isLocal { return local }
        let live = Set(machines.remoteDaemons.map(ObjectIdentifier.init))
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
