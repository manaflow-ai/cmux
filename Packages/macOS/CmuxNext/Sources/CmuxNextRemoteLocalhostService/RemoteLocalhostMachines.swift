public import CmuxNextDaemon
public import CmuxNextDaemonService

/// The app's machines as remote localhost sees them (the app's
/// `MachineRegistry`): which daemon holds a tab, each machine's badge name
/// and where the person's own choices live.
@MainActor
public protocol RemoteLocalhostMachines: AnyObject {
    /// This Mac's daemon, home of personal state.
    var local: DaemonService { get }
    var daemons: [DaemonService] { get }
    func daemon(forTab tab: TabModel) -> DaemonService
    func daemon(machine machineID: String) -> DaemonService?
    func machineBadge(_ machineID: String) -> String?
    /// Workspace `id`'s personal-state address: the session that owns it and its key.
    func personalAddress(ofWorkspace id: String) -> (session: String, key: String)?
    /// The private IPv4 address of Cloud machine `machineID` on its Cloud network, which the app
    /// reaches over its own WireGuard tunnel; nil for any other machine.
    func cloudTunnelAddress(machine machineID: String) -> String?
    /// The badge name of Cloud machine `machineID`, matched without case (Open Desktop's URL
    /// carries the id lowercased); nil for an unknown machine.
    func cloudMachineBadge(machine machineID: String) -> String?
}

extension RemoteLocalhostMachines {
    public func cloudTunnelAddress(machine machineID: String) -> String? { nil }
    public func cloudMachineBadge(machine machineID: String) -> String? { machineBadge(machineID) }
}
