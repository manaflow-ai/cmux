import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextSidebar

extension ServerMachineSession {
    /// A paired server's section header, named after the server: over SSH
    /// the link's state first (sign-in failed, unreachable), then the
    /// daemon's connection and capability level; on this Mac the daemon's
    /// connection only. An offline server reads unreachable, never blocking.
    func sidebarMachine(machines: MachineRegistry) -> SidebarMachine {
        let session = self
        let compatibility = machines.compatibility(of: session.daemon)
        let status: SidebarMachine.Status
        if let link = session.link {
            status = switch SidebarBridge.sshStatus(link, compatibility: compatibility) {
            // Nothing to install from here: the brain's binaries belong to its installer.
            case .installRequired, .installing: .unreachable
            case let other: other
            }
        } else {
            // The brain's socket on this Mac: a down brain is unreachable, not "connecting".
            let base = SidebarBridge.machine(for: session.daemon, name: session.name, kind: .server, compatibility: compatibility).status
            status = switch session.daemon.store.connectionState {
            case .failed, .disconnected: base == .updateRequired ? base : .unreachable
            case .connecting, .connected: base
            }
        }
        let detail: String? = switch session.reach.route {
        case .ssh(let host): [host.destination.description, session.link.flatMap(RemoteStrings.detail)].compactMap { $0 }.joined(separator: "\n")
        case .unix, .overlay: nil
        }
        return SidebarMachine(id: MachineID(session.machineID), name: session.name, kind: .server, status: status, detail: detail)
    }
}

extension ServerMachineSession {
    /// Why the server's daemon is not connected: the link dial's refusal
    /// (owner session refused, unknown peer) or the connection's end.
    var notConnectedReason: String? {
        switch daemon.store.connectionState {
        case .failed(let message), .disconnected(let message): message
        case .connecting, .connected: nil
        }
    }
}
