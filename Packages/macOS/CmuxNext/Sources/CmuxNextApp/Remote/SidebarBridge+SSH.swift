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
        switch session.linkStatus {
        case .offline: return .offline
        case .installing: return .installing
        case .authFailed, .hostKeyUntrusted: return .authFailed
        case .unreachable: return .unreachable
        case .needsInstall(.protocolMismatch): return .updateRequired
        case .needsInstall, .installFailed: return .installRequired
        case .connecting, .connected, .failed:
            guard case .connected = session.daemon.store.connectionState else {
                if let compatibility, compatibility.level == .incompatible, session.daemon.startup.isUnavailable { return .updateRequired }
                return .connecting
            }
            if compatibility?.level == .limited { return .updateAvailable }
            return .connected
        }
    }
}
