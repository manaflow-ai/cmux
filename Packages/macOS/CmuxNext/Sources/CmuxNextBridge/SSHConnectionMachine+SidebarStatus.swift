public import CmuxNextDaemon
public import CmuxNextRemote
public import CmuxNextSidebar

extension SSHConnectionMachine.Status {
    /// An SSH machine header's status from its link status and its daemon.
    /// `startupFailed`: the daemon gave up after SSH reached the machine
    /// (`SSHMachineSession.daemonFailure`): Failed to start, not Connecting (cx-zdh8).
    /// A later drop reads as the link says (connecting, reconnecting): the link is the layer that
    /// redials (cmuxterm-hq#7766).
    public func sidebarStatus(startupFailed: Bool, daemonConnected: Bool,
                              compatibility: DaemonCompatibility?) -> SidebarMachine.Status {
        switch self {
        case .offline: return .offline
        case .installing: return .installing
        case .reconnecting: return .reconnecting
        case .authFailed, .hostKeyUntrusted: return .authFailed
        case .unreachable: return .unreachable
        case .needsInstall(.protocolMismatch), .needsInstall(.refused(.protocolOlder)): return .updateRequired
        case .needsInstall(.refused(.protocolNewer)): return .failed
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
