import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

/// An SSH machine that is connecting in the one-list sidebar (cx-gaq9): the
/// list has no computer rows (cx-mdo0), so a machine with no workspace row
/// yet shows one pending row, "Connecting to <host>…", from Connect until its
/// first workspace is listed or the link stops connecting. The state is the
/// link's and the daemon's (`SidebarBridge.sshStatus`); this type only
/// presents it, so the sidebar bridge does not grow.
enum SSHConnectingRows {
    nonisolated static let prefix = "ssh-connecting:"

    /// `sections` with one pending row per SSH machine that is connecting
    /// (or installing, or connected while its tree loads) and lists no
    /// workspace in this window.
    static func adding(_ machines: MachineRegistry, to sections: [SidebarRowSection]) -> [SidebarRowSection] {
        var sections = sections
        for session in machines.ssh {
            let machineID = MachineID(session.machineID)
            let index = sections.firstIndex { $0.machine?.id == machineID }
            if let index, !sections[index].workspaces.isEmpty { continue }
            let status = SidebarBridge.sshStatus(session, compatibility: machines.compatibility(of: session.daemon))
            let loading = status == .connected && !session.daemon.store.isLoaded
            guard status == .connecting || status == .installing || loading else { continue }
            let row = SidebarWorkspace(
                id: WorkspaceID(prefix + session.machineID), machineID: machineID,
                title: RemoteStrings.sidebarConnecting(session.host.label), kind: .terminal,
                progress: SidebarProgress(value: nil), isClosable: false,
                stage: status == .installing ? RemoteStrings.detail(session) : nil)
            if let index {
                sections[index].nodes.append(.workspace(row))
            } else {
                sections.append(SidebarSection(kind: .machine(SidebarBridge.sshMachine(session, machines: machines)), nodes: [.workspace(row)]))
            }
        }
        return sections
    }

    /// A connecting row: no workspace yet, so no daemon command.
    nonisolated static func isRow(_ id: WorkspaceID) -> Bool { id.rawValue.hasPrefix(prefix) }

    /// The machine id of a connecting row.
    nonisolated static func machine(of id: WorkspaceID) -> String? {
        isRow(id) ? String(id.rawValue.dropFirst(prefix.count)) : nil
    }

    /// Gestures on a connecting row (select, close, drag, rename) do nothing
    /// and snap back; the row's menu is its machine's (Reconnect, Disconnect,
    /// Forget). False for intents that do not touch a connecting row.
    static func handle(_ intent: SidebarIntent, bridge: SidebarBridge) -> Bool {
        switch intent {
        case .select(let id) where isRow(id), .rename(let id, _) where isRow(id):
            bridge.resync()
            return true
        case .close(let ids) where ids.contains(where: isRow),
             .reorder(let ids, _) where ids.contains(where: isRow),
             .move(let ids, _) where ids.contains(where: isRow):
            bridge.resync()
            return true
        default:
            return false
        }
    }
}
