import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextSidebar

extension SidebarBridge {
    /// An SSH machine's section header: the link's state first (offline,
    /// sign-in failed, unreachable, install needed, installing), then the
    /// daemon's connection and capability level, like a Cloud machine.
    static func sshMachine(_ session: SSHMachineSession, machines: MachineRegistry) -> SidebarMachine {
        let compat = machines.compatibility(of: session.daemon), header = sshHeader(session, compatibility: compat), status = header?.status ?? .connecting
        let detail = header?.compatibilityDetail == true ? compat.map(CloudStrings.compatibility) : RemoteStrings.detail(session)
        let tooltip = sshTooltip(destination: session.host.destination, session: session.host.session, detail: detail, updates: machines.updates)
        return SidebarMachine(id: MachineID(session.machineID), name: session.host.label, kind: .ssh, status: status, detail: tooltip)
    }

    /// The header the sidebar draws for machine `machineID` (a Cloud machine, an SSH host or a
    /// paired server), built by the functions `sections` uses: the one read of a machine's link
    /// state, for the sidebar and the agent pane's composer strip (``AgentPaneMachineLink``). Nil
    /// for this Mac and a machine the app does not know.
    static func machineHeader(_ machineID: String, in machines: MachineRegistry) -> SidebarMachine? {
        if let cloud = machines.session(machineID) {
            return CloudCreationRows.machine(cloud, compatibility: machines.compatibility(of: cloud.daemon), limits: machines.cloudLimits, updates: machines.updates)
        }
        if let ssh = machines.sshSession(machineID) { return sshMachine(ssh, machines: machines) }
        return machines.server(machineID)?.sidebarMachine(machines: machines)
    }

    /// Machine `machineID`'s link for an agent pane's composer strip: the header's same word.
    static func paneLink(_ machineID: String, in machines: MachineRegistry) -> AgentPaneMachineLink.State? {
        machineHeader(machineID, in: machines).map {
            AgentPaneMachineLink.State(machine: machineID, link: $0.status.linkState.rawValue, words: $0.status.words)
        }
    }

    /// What a chat that needs machine `machineID` finds its link doing: only a link that dropped
    /// or never came up reconnects on use (``MachineLinkState/reconnectsOnUse(_:)``), never an SSH session in use (G5).
    static func paneUse(_ machineID: String, in machines: MachineRegistry) -> AgentPaneMachineLink.Use {
        switch SidebarBridgeRules().paneUse(waitsForUser: machines.sshSession(machineID)?.waitsForUser == true, header: machineHeader(machineID, in: machines)?.status) {
        case "up": .up
        case "coming": .coming
        case "down": .down
        default: .stuck
        }
    }

    /// An ssh machine header's tooltip: the destination (with its cmux-tui session when not the
    /// default), then `detail`, then the machine's daemon update line (`updates`, the app's board). One
    /// place for the live header and `debug.daemon_update`'s fixture.
    static func sshTooltip(destination: SSHDestination, session: String, detail: String?, updates: DaemonUpdateBoard) -> String {
        [destination.description + (session == RemoteSessionName.defaultName ? "" : " · " + session), detail,
         updates.detail(sshHost: destination.host)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func sshStatus(_ session: SSHMachineSession, compatibility: DaemonCompatibility?) -> SidebarMachine.Status {
        sshHeader(session, compatibility: compatibility)?.status ?? .connecting
    }

    /// The link's status, except a connected machine offered a newer cmux-tui says Update Available (`SidebarBridgeRules.sshStatus`).
    private static func sshHeader(_ session: SSHMachineSession, compatibility: DaemonCompatibility?) -> (status: SidebarMachine.Status, compatibilityDetail: Bool)? {
        let connected = if case .connected = session.daemon.store.connectionState { true } else { false }
        let link = session.linkStatus.sidebarStatus(startupFailed: session.daemonFailure != nil, daemonConnected: connected, compatibility: compatibility)
        return SidebarBridgeRules().sshStatus(link: link, updateOffered: session.updateOffered, compatibilityKnown: compatibility != nil)
    }
}
