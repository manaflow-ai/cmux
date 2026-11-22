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
        let tooltip = [session.host.destination.description + (session.host.session == RemoteSessionName.defaultName ? "" : " · " + session.host.session),
                       detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        return SidebarMachine(id: MachineID(session.machineID), name: session.host.label, kind: .ssh, status: status, detail: tooltip)
    }

    static func sshStatus(_ session: SSHMachineSession, compatibility: DaemonCompatibility?) -> SidebarMachine.Status {
        let connected = if case .connected = session.daemon.store.connectionState { true } else { false }
        return sshStatus(link: session.linkStatus, startupFailed: session.daemonFailure != nil, daemonConnected: connected, compatibility: compatibility)
    }

    /// `startupFailed`: the daemon gave up after SSH reached the machine
    /// (`SSHMachineSession.daemonFailure`): Failed to start, not Connecting (cx-zdh8).
    static func sshStatus(link: SSHConnectionMachine.Status, startupFailed: Bool, daemonConnected: Bool,
                          compatibility: DaemonCompatibility?) -> SidebarMachine.Status {
        switch link {
        case .offline: return .offline
        case .installing: return .installing
        case .authFailed, .hostKeyUntrusted: return .authFailed
        case .unreachable: return .unreachable
        case .needsInstall(.protocolMismatch): return .updateRequired
        case .needsInstall, .installFailed: return .installRequired
        case .failed: return daemonConnected ? .connected : .failed
        case .connecting, .connected:
            guard daemonConnected else {
                if let compatibility, compatibility.level == .incompatible, startupFailed { return .updateRequired }
                return startupFailed ? .failed : .connecting
            }
            if compatibility?.level == .limited { return .updateAvailable }
            return .connected
        }
    }
}
