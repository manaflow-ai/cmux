import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextSidebar

extension SidebarBridge {
    /// An SSH machine's section header: the link's state first (offline,
    /// sign-in failed, unreachable, install needed, installing), then the
    /// daemon's connection and capability level, like a Cloud machine.
    static func sshMachine(_ session: SSHMachineSession, machines: MachineRegistry) -> SidebarMachine {
        let status = sshStatus(session, compatibility: machines.compatibility(of: session.daemon))
        var detail = RemoteStrings.detail(session)
        if status == .updateRequired || status == .updateAvailable, let compat = machines.compatibility(of: session.daemon) {
            detail = CloudStrings.compatibility(compat)
        }
        let tooltip = sshTooltip(destination: session.host.destination, session: session.host.session, detail: detail)
        return SidebarMachine(id: MachineID(session.machineID), name: session.host.label, kind: .ssh, status: status, detail: tooltip)
    }

    /// The header the sidebar draws for machine `machineID` (a Cloud machine, an SSH host or a
    /// paired server), built by the functions `sections` uses: the one read of a machine's link
    /// state, for the sidebar and the agent pane's composer strip (``AgentPaneMachineLink``). Nil
    /// for this Mac and a machine the app does not know.
    static func machineHeader(_ machineID: String, in machines: MachineRegistry) -> SidebarMachine? {
        if let cloud = machines.session(machineID) {
            return CloudCreationRows.machine(cloud, compatibility: machines.compatibility(of: cloud.daemon), limits: machines.cloudLimits)
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
        if machines.sshSession(machineID)?.waitsForUser == true { return .stuck }
        guard let status = machineHeader(machineID, in: machines)?.status else { return .stuck }
        switch status.linkState {
        case .connected: return .up
        case .connecting: return .coming
        case .offline, .paused, .attention: return MachineLinkState.reconnectsOnUse(status) ? .down : .stuck
        }
    }

    /// An ssh machine header's tooltip: the destination (with its cmux-tui session when not the
    /// default), then `detail`, then the machine's daemon update line (``DaemonUpdateBoard``). One
    /// place for the live header and `debug.daemon_update`'s fixture.
    static func sshTooltip(destination: SSHDestination, session: String, detail: String?) -> String {
        [destination.description + (session == RemoteSessionName.defaultName ? "" : " · " + session), detail,
         DaemonUpdateBoard.shared.detail(sshHost: destination.host)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func sshStatus(_ session: SSHMachineSession, compatibility: DaemonCompatibility?) -> SidebarMachine.Status {
        let connected = if case .connected = session.daemon.store.connectionState { true } else { false }
        let status = sshStatus(link: session.linkStatus, startupFailed: session.daemonFailure != nil, daemonConnected: connected, compatibility: compatibility, retriesSpent: session.retriesSpent)
        return status == .connected && session.updateOffered ? .updateAvailable : status
    }

    /// `startupFailed`: the daemon gave up after SSH reached the machine
    /// (`SSHMachineSession.daemonFailure`): Failed to start, not Connecting (cx-zdh8).
    /// `retriesSpent`: a later reconnect gave up: Offline, not Connecting forever (HQ #4877 G4).
    static func sshStatus(link: SSHConnectionMachine.Status, startupFailed: Bool, daemonConnected: Bool,
                          compatibility: DaemonCompatibility?, retriesSpent: Bool = false) -> SidebarMachine.Status {
        switch link {
        case .offline: return .offline
        case .installing: return .installing
        case .reconnecting: return daemonConnected || !retriesSpent ? .reconnecting : .offline
        case .authFailed, .hostKeyUntrusted: return .authFailed
        case .unreachable: return .unreachable
        case .needsInstall(.protocolMismatch), .needsInstall(.refused(.protocolOlder)): return .updateRequired
        case .needsInstall(.refused(.protocolNewer)): return .failed
        case .needsInstall, .installFailed: return .installRequired
        case .failed: return daemonConnected ? .connected : .failed
        case .connecting, .connected:
            guard daemonConnected else {
                if let compatibility, compatibility.level == .incompatible, startupFailed { return .updateRequired }
                return startupFailed ? .failed : retriesSpent ? .offline : .connecting
            }
            if compatibility?.level == .limited { return .updateAvailable }
            return .connected
        }
    }
}
