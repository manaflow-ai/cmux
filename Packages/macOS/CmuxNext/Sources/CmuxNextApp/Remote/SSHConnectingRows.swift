import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

/// An SSH machine that is connecting in the one-list sidebar (cx-gaq9): the
/// list has no computer rows (cx-mdo0), so a machine with no workspace row
/// yet shows one pending row, "Connecting to <host>…", from Connect until its
/// first workspace is listed or the link stops connecting (a link that
/// fails or goes offline ends the row; the machine's surface says why). The state is the
/// link's and the daemon's (`SidebarBridge.sshStatus`); this type only
/// presents it, so the sidebar bridge does not grow.
enum SSHConnectingRows {
    nonisolated static let prefix = "ssh-connecting:"

    /// `sections` with one pending row per SSH machine that is connecting
    /// or installing and lists no row in this window. The row is a titled
    /// placeholder: never selected, dragged, renamed or closed, and never
    /// saved in the sidebar snapshot (the placeholder guards).
    static func adding(_ machines: MachineRegistry, to sections: [SidebarRowSection]) -> [SidebarRowSection] {
        var sections = sections
        for session in machines.ssh {
            let machineID = MachineID(session.machineID)
            let index = sections.firstIndex { $0.machine?.id == machineID }
            if let index, !sections[index].workspaces.isEmpty { continue }
            let status = SidebarBridge.sshStatus(session, compatibility: machines.compatibility(of: session.daemon))
            guard status == .connecting || status == .installing else { continue }
            let row = SidebarWorkspace(
                id: WorkspaceID(prefix + session.machineID), machineID: machineID,
                title: RemoteStrings.sidebarConnecting(session.host.label), kind: .terminal,
                progress: SidebarProgress(value: nil), rowState: .placeholder, isClosable: false,
                stage: status == .installing ? RemoteStrings.detail(session) : nil)
            if let index {
                sections[index].nodes.append(.workspace(row))
            } else {
                sections.append(SidebarSection(kind: .machine(SidebarBridge.sshMachine(session, machines: machines)), nodes: [.workspace(row)]))
            }
        }
        return sections
    }

    /// The machine id of a connecting row, whose menu is its machine's.
    nonisolated static func machine(of id: WorkspaceID) -> String? {
        id.rawValue.hasPrefix(prefix) ? String(id.rawValue.dropFirst(prefix.count)) : nil
    }
}
