public import CmuxNextDaemon
public import CmuxNextDaemonService

/// Machine and workspace values shared by lower feature modules. The protocol
/// keeps the registry implementation and its session types in CmuxNextApp.
@MainActor
public protocol MachineWorkspaceProviding: AnyObject {
    var localDaemon: DaemonService { get }
    var allWorkspaces: [(WorkspaceModel, DaemonService)] { get }
    func workspaceMachineName(_ daemon: DaemonService) -> String?
}
