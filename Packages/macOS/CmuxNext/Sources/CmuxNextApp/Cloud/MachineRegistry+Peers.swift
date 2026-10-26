import CmuxNextAgentLanes
import CmuxNextBridge
import CmuxNextSidebar
import Foundation

extension MachineRegistry {
    /// The sidebar name (``machineName(_:)``) of the machine an acpmux peer is: the SSH machine
    /// whose host, short host or sidebar name is the peer's name, else the Cloud machine or
    /// server of that name. Nil when no machine the app shows matches.
    func machineName(peer: String) -> String? {
        machineID(peer: peer).flatMap { machineName($0) }
    }

    /// The id of the machine an acpmux peer is, matched as ``machineName(peer:)`` matches.
    func machineID(peer: String) -> String? {
        let wanted = peer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        let matches = { (names: [String]) in names.contains { $0.lowercased() == wanted } }
        return sshMachine(named: [wanted])?.machineID
            ?? cloud.first { matches([$0.machine.title]) }?.machineID
            ?? servers.first { matches([$0.name]) }?.machineID
    }

    /// `sections` with each machine header that is an acpmux peer carrying its room
    /// (`RemoteMachinesSidebar.rooms`, by peer name); a header draws it only as a remote group.
    func withMachineRooms(_ sections: [SidebarRowSection], rooms: [String: SidebarMachine.Room]) -> [SidebarRowSection] {
        guard !rooms.isEmpty else { return sections }
        var byMachine: [String: SidebarMachine.Room] = [:]
        for (peer, room) in rooms.sorted(by: { $0.key < $1.key }) {
            if let id = machineID(peer: peer), byMachine[id] == nil { byMachine[id] = room }
        }
        return sections.map { section in
            guard case .machine(var machine) = section.kind, machine.kind != .local,
                  let room = byMachine[machine.id.rawValue] else { return section }
            machine.room = room
            var drawn = section
            drawn.kind = .machine(machine)
            return drawn
        }
    }

    /// The SSH machine whose host, short host or sidebar name is one of `names` (any case, a
    /// trailing dot ignored), as ``machineName(peer:)`` matches a peer.
    func sshMachine(named names: [String]) -> SSHMachineSession? {
        let normalize = { (name: String) in
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return name.hasSuffix(".") ? String(name.dropLast()) : name
        }
        let wanted = Set(names.map(normalize).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return nil }
        return ssh.first { session in
            [session.host.destination.host, session.host.destination.displayName, session.host.label]
                .contains { wanted.contains(normalize($0)) }
        }
    }

    /// The SSH machine whose route host or short display host is one of `names`. This intentionally
    /// ignores a custom sidebar label: tailnet discovery must match the route, not a person's title.
    func sshMachine(routeNames names: [String]) -> SSHMachineSession? {
        let normalize = { (name: String) in
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return name.hasSuffix(".") ? String(name.dropLast()) : name
        }
        let wanted = Set(names.map(normalize).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return nil }
        return ssh.first { session in
            [session.host.destination.host, session.host.destination.displayName]
                .contains { wanted.contains(normalize($0)) }
        }
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
