public import CmuxNextDaemon
public import CmuxNextDaemonService

/// A value-only view of one app window. Feature modules can consume this seam
/// without importing the App's WindowController or WindowState.
@MainActor
public protocol WindowSnapshotProviding: AnyObject {
    var windowID: String { get }
    var workspaceID: String? { get }
    var isKeyWindow: Bool { get }
}

/// The daemon and workspace routing operations shared by app features. Each
/// requirement stays a narrow service protocol so consumers do not depend on
/// the concrete MachineRegistry or AppServices composition root.
@MainActor
public protocol DaemonRoutingProviding: AnyObject {
    var localDaemon: DaemonService { get }
    func daemon(machineID: String) -> DaemonService?
    func daemon(workspaceID: String) -> DaemonService?
    func machineName(_ machineID: String) -> String?
}

/// Read-only window projections exposed to lower feature modules.
@MainActor
public protocol WindowSnapshotsProviding: AnyObject {
    var activeWindowSnapshot: (any WindowSnapshotProviding)? { get }
    var windowSnapshots: [any WindowSnapshotProviding] { get }
}

/// The first stable host seam for feature modules. Concrete app services
/// conform in CmuxNextApp; lower modules only depend on these protocols.
@MainActor
public protocol AppServicesProviding: AnyObject {
    var daemonRouting: any DaemonRoutingProviding { get }
    var windowSnapshotService: any WindowSnapshotsProviding { get }
    var windowAccess: any WindowAccessProviding { get }
    var machineWorkspaces: any MachineWorkspaceProviding { get }
    var pageActions: any PageActionProviding { get }
}

/// ID-based window access for feature modules. The concrete WindowManager stays
/// in CmuxNextApp; consumers receive only immutable snapshots and IDs.
@MainActor
public protocol WindowAccessProviding: AnyObject {
    var activeWindowSnapshot: (any WindowSnapshotProviding)? { get }
    var windowSnapshots: [any WindowSnapshotProviding] { get }
    func snapshot(windowID: String) -> (any WindowSnapshotProviding)?
    func ownerWindowID(workspaceID: String) -> String?
}
