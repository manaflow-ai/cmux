import CmuxNextAppCore
import CmuxNextBridge

// The app keeps these names as source-compatible aliases while their values and
// close path compile in the lower core target. Feature files therefore move by
// import graph without a behavior change in this PR.
typealias WorkspaceSpawn = CmuxNextAppCore.WorkspaceSpawn
typealias WorkspaceClose = CmuxNextAppCore.WorkspaceClose
typealias WorkspaceSpawnSidebar = CmuxNextAppCore.WorkspaceSpawnSidebar

@MainActor extension SidebarBridge: WorkspaceSpawnSidebar {
    var sections: [SidebarRowSection] { model.sections }
}

extension WorkspaceSpawn {
    /// `tabs.terminalFirst` (cmux Classic Mode, #23021): a person's new workspace or window opens
    /// a terminal, as in cmux classic, not the New Tab page. A first chat or session still opens.
    @MainActor mutating func followClassicMode(_ services: AppServices) {
        if NewTabKind.terminalFirst(services) { opensNewTabPage = false }
    }
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
}

// Legacy app handlers still use the concrete group editor while the core
// callback carries only the read-only sidebar projection.
extension WorkspaceSpawnSidebar {
    var groupFlow: SidebarGroupFlow {
        (self as! SidebarBridge).groupFlow
    }
}
