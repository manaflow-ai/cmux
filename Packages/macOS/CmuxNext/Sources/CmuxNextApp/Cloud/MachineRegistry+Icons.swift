import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

// Machine icons (`session-icon-v1`, cx-qno.11.4): the home daemon's session
// registry keeps each machine's icon on its session record. The app only
// reads the record and sends `set-session-icon`; the daemon validates and
// stores it.
extension MachineRegistry {
    /// The session id the home registry keys machine `machineID` by: its
    /// daemon's `registry_id`, the id `SessionRegistrar` records it under
    /// with `put-session` (this Mac's own row included). Nil before the
    /// daemon's tree has loaded.
    func sessionID(machine machineID: String) -> String? {
        anyDaemon(machine: machineID)?.store.registryID
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
