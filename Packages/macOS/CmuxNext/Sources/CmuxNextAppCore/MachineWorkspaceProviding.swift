public import CmuxNextDaemon
public import CmuxNextDaemonService
import CmuxNextSidebar

/// Machine and workspace values shared by lower feature modules. The protocol
/// keeps the registry implementation and its session types in CmuxNextApp.
@MainActor
public protocol MachineWorkspaceProviding: AnyObject {
    var localDaemon: DaemonService { get }
    var allWorkspaces: [(WorkspaceModel, DaemonService)] { get }
    func workspaceMachineName(_ daemon: DaemonService) -> String?
}

public extension DaemonRoutingProviding {
    /// The name of `daemon`'s machine as a row names another machine, nil for this Mac (the local
    /// Chief runs on this Mac, as the sidebar's machine marks say).
    func otherMachineName(_ daemon: DaemonService) -> String? {
        daemon.isLocal || MachineID(daemon.machineID).isLocalChief ? nil : machineName(daemon.machineID)
    }
}

public extension AppServicesProviding {
    /// Every machine's workspaces, local first, each with its machine's name when it is not this
    /// Mac: what the agent pages' cmux link chips name (``AgentPaneLinkPlaces/follow(_:)``).
    func linkPlaceWorkspaces() -> [(WorkspaceModel, host: String?)] {
        machineWorkspaces.allWorkspaces.map { ($0, host: daemonRouting.otherMachineName($1)) }
    }
}
