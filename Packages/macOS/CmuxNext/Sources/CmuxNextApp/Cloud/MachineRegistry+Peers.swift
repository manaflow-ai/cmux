import CmuxNextAgentLanes
import Foundation

extension MachineRegistry {
    /// The sidebar name (``machineName(_:)``) of the machine an acpmux peer is: the SSH machine
    /// whose host, short host or sidebar name is the peer's name, else the Cloud machine or
    /// server of that name. Nil when no machine the app shows matches.
    func machineName(peer: String) -> String? {
        let wanted = peer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        let matches = { (names: [String?]) in names.contains { $0?.lowercased() == wanted } }
        let id = ssh.first { matches([$0.host.destination.host, $0.host.destination.displayName, $0.host.label]) }?.machineID
            ?? cloud.first { matches([$0.machine.title]) }?.machineID
            ?? servers.first { matches([$0.name]) }?.machineID
        return id.flatMap { machineName($0) }
    }

    /// The other machines whose agent chats the sidebar's Priority view ranks: each reachable
    /// one's daemon tree under its sidebar name. A tree that runs on this Mac (``tabBadge(_:)``
    /// nil: a server reached at a Unix socket here) is named as this Mac is.
    var priorityMachines: [SidebarPriorityMachine] {
        remoteDaemons.compactMap { daemon in
            guard self.daemon(machine: daemon.machineID) != nil else { return nil }
            return SidebarPriorityMachine(name: tabBadge(daemon.machineID).flatMap { _ in machineName(daemon.machineID) }, store: daemon.store)
        }
    }
}
