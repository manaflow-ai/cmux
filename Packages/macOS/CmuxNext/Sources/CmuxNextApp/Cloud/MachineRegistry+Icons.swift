import CmuxNextBridge
import CmuxNextBridgeUI
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextSidebar

// Machine icons (`session-icon-v1`, cx-qno.11.4): the home daemon's session
// registry keeps each machine's icon on its session record. The app only
// reads the record and sends `set-session-icon`; the daemon validates and
// stores it.
extension MachineRegistry {
    /// The session id the home registry keys machine `machineID` by: its
    /// daemon's `registry_id`, the id `SessionRegistrar` records it under
    /// with `put-session` (this Mac's own row included). Before that daemon
    /// loads this run (an SSH host that is down, a stopped Cloud machine, an
    /// unreachable server), the home record whose `transport` names it.
    func sessionID(machine machineID: String) -> String? {
        if let id = anyDaemon(machine: machineID)?.store.registryID { return id }
        return local.store.personal.sessions.first { Self.machineID(transport: $0.transport) == machineID }?.id
    }

    /// The machine a registry `transport` (`SessionRegistrar.transport`)
    /// names, read back as the services that restore it read it: this Mac,
    /// a Cloud machine's id, an SSH route (`SSHService.restore`) or a paired
    /// server's host (`ServerReachService.restore`); nil for anything else.
    static func machineID(transport: JSONValue?) -> String? {
        guard let fields = transport.flatMap(SSHService.fields) else { return nil }
        switch fields["kind"] {
        case "local": return localID
        case "cloud": return fields["machine"]
        default: return SSHHost(transportFields: fields)?.machineID ?? ServerReach(transportFields: fields)?.machineID
        }
    }

    /// Machine `machineID`'s icon value in the home session registry; nil
    /// when it has none or is not recorded yet.
    func icon(machine machineID: String) -> String? {
        guard let session = sessionID(machine: machineID) else { return nil }
        return local.store.personal.session(session)?.icon
    }

    /// `sections` with each machine header carrying its icon. A stored
    /// asset is read from the home daemon, which holds machine icons' assets.
    func withMachineIcons(_ sections: [SidebarRowSection]) -> [SidebarRowSection] {
        let asset = IconAssetImages.shared.sidebarIcon(owner: local)
        return sections.map { section in
            guard case .machine(var machine) = section.kind else { return section }
            machine.icon = SidebarMapping.machineIcon(icon(machine: machine.id.rawValue), asset: asset)
            var drawn = section
            drawn.kind = .machine(machine)
            return drawn
        }
    }
}
