import CmuxNextAppCore
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextActions

// The app keeps these names as source-compatible aliases while their values and
// close path compile in the lower core target. Feature files therefore move by
// import graph without a behavior change in this PR.
typealias WorkspaceSpawn = CmuxNextAppCore.WorkspaceSpawn
typealias WorkspaceClose = CmuxNextAppCore.WorkspaceClose
typealias WorkspaceSpawnSidebar = CmuxNextAppCore.WorkspaceSpawnSidebar
typealias WorkspaceSelectionCloseFlow = CmuxNextAppCore.WorkspaceSelectionCloseFlow
typealias BulkClosePlan<Object> = CmuxNextAppCore.BulkClosePlan<Object>

@MainActor extension SidebarBridge: WorkspaceSpawnSidebar {
    var sections: [SidebarRowSection] { model.sections }
}

extension AppServices: DaemonRoutingProviding {
    var localDaemon: DaemonService { daemon }

    func daemon(machineID: String) -> DaemonService? {
        machines.daemons.first { $0.machineID == machineID }
    }

    func daemon(workspaceID: String) -> DaemonService? {
        machines.daemon(forWorkspace: workspaceID)
    }

    func machineName(_ machineID: String) -> String? {
        machines.machineName(machineID)
    }
}

extension WindowController: WindowSnapshotProviding {
    var windowID: String { state.id }
    var workspaceID: String? { state.workspaceID }
    var isKeyWindow: Bool { window?.isKeyWindow == true }
}

extension AppServices: WindowSnapshotsProviding {
    var activeWindowSnapshot: (any WindowSnapshotProviding)? { windows.active }
    var windowSnapshots: [any WindowSnapshotProviding] { windows.controllers }
}

extension AppServices: AppServicesProviding {
    var daemonRouting: any DaemonRoutingProviding { self }
    var windowSnapshotService: any WindowSnapshotsProviding { self }
    var windowAccess: any WindowAccessProviding { self }
    var machineWorkspaces: any MachineWorkspaceProviding { self }
    var pageActions: any PageActionProviding { self }
}

extension AppServices: WindowAccessProviding {
    func snapshot(windowID: String) -> (any WindowSnapshotProviding)? {
        windows.controller(for: windowID)
    }

    func ownerWindowID(workspaceID: String) -> String? {
        windows.registry.value.owner(of: workspaceID)
    }
}

extension AppServices: MachineWorkspaceProviding {
    var allWorkspaces: [(WorkspaceModel, DaemonService)] { machines.allWorkspaces }

    func workspaceMachineName(_ daemon: DaemonService) -> String? {
        daemon.identity?.machineName ?? machines.machineName(daemon.machineID)
    }
}

extension AppServices: PageActionProviding {
    func actionDescriptor(for id: ActionID) -> ActionDescriptor? { registry.descriptor(for: id) }

    func actionTitle(for id: ActionID) -> String? { registry.title(for: id) }

    func isActionAvailable(_ id: ActionID) -> Bool { registry.isAvailable(id) }

    func performAction(_ id: ActionID, invocation: ActionInvocation) -> Bool {
        registry.perform(id, invocation: invocation)
    }
}
