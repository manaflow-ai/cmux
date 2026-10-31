import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

/// The one-list sidebar's "Connecting to <host>…" rows (`ConnectingRowWindows`; the list has no
/// computer rows, cx-mdo0). The state is the link's and the daemon's (`SidebarBridge.sshStatus`).
enum SSHConnectingRows {
    /// `sections` with one pending row per SSH machine that is connecting or installing, lists no row
    /// here and lists in `window` (nil: any). The row is a titled placeholder: never selected, dragged,
    /// renamed or closed, and never saved in the sidebar snapshot (the placeholder guards).
    static func adding(_ machines: MachineRegistry, to sections: [SidebarRowSection], window: String?, windows: ConnectingRowWindows) -> [SidebarRowSection] {
        var sections = sections
        for session in machines.ssh where window == nil || windows.owner(requestedBy: session.connectingWindow) == window {
            let machineID = MachineID(session.machineID)
            let index = sections.firstIndex { $0.machine?.id == machineID }
            if let index, !sections[index].workspaces.isEmpty { continue }
            let status = SidebarBridge.sshStatus(session, compatibility: machines.compatibility(of: session.daemon))
            guard status == .connecting || status == .installing else { continue }
            let row = SidebarWorkspace(
                id: WorkspaceID(ConnectingRowWindows.prefix + session.machineID), machineID: machineID,
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
}

extension WindowManager {
    func connectingRowWindows(making id: String?) -> ConnectingRowWindows { ConnectingRowWindows(open: controllers.map(\.state.id), incognito: isIncognito(window:), making: id) }
}
