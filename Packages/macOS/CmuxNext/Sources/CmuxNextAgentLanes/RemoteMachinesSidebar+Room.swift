public import CmuxNextAgentPane
public import CmuxNextSidebar

extension RemoteMachinesSidebar {
    /// Each reachable peer's room by its acpmux name, for the remote groups' headers
    /// (`SidebarMachine.Room`): what the gated peer read last found, so reading it costs nothing
    /// and its changes redraw the sidebar through `machines`. Empty while the room style is off.
    public var rooms: [String: SidebarMachine.Room] {
        guard SidebarTunables.remoteMachineResources.value != .off else { return [:] }
        var rooms: [String: SidebarMachine.Room] = [:]
        for machine in machines {
            guard machine.online, let resources = machine.resources else { continue }
            rooms[machine.peer] = Self.room(resources, name: machine.peer)
        }
        return rooms
    }

    /// One reading as a header shows it: the room on its line, the whole reading (free disk
    /// always) on hover, and the room again for VoiceOver after the machine's name.
    static func room(_ r: AcpmuxPeerList.Resources, name: String) -> SidebarMachine.Room {
        let line = RemoteMachinesStrings.resources(r)
        var tip = line
        if let disk = r.diskFreeGB, disk >= RemoteMachinesStrings.lowDiskGB {
            tip = RemoteMachinesStrings.named(tip, RemoteMachinesStrings.diskFree(disk))
        }
        return SidebarMachine.Room(line: line, toolTip: tip, spoken: line)
    }
}

extension RemoteMachinesStrings {
    /// Free disk, as the room line words it when low.
    static func diskFree(_ gb: Int) -> String {
        String(format: String(localized: "sidebar.remoteMachines.disk", defaultValue: "%lld GB disk", bundle: .module), gb)
    }
}
