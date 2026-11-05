import CmuxNextDaemon
import CmuxNextHibernation

// Workspace hibernation (plans/cmux-next/workspace-hibernation-DESIGN.md): one-line forwards to the App's owners.
extension AppServices: WorkspaceHibernationHost {
    func hibernationResidents() -> [WorkspaceHibernationResident] { windows.hibernationResidents(in: machines.daemons.map(\.store), holdsMemory: holdsTabMemory) }
    func hibernationShownWorkspaces() -> Set<String> { windows.shownWorkspaceIDs }
    func hibernationShownSpaces() -> Set<String> { Set(windows.shownSpaceIDs.map(\.rawValue)) }
    func hibernationPolicy() -> WorkspaceHibernationPlanner.Policy { WorkspaceHibernationPlanner.Policy(settings?.snapshot.workspaceHibernation) }
    func hibernate(workspace id: String) { hibernateWorkspace(id) }
    func hibernate(workspace id: String, byPerson: Bool) { hibernateWorkspace(id, byPerson: byPerson) }
    func freeingPolicy() -> WorkspaceFreeingPlanner.Policy { WorkspaceFreeingPlanner.Policy(settings?.snapshot.workspaceHibernation) }
    func freeingTerminals(in workspaces: Set<String>) -> [WorkspaceFreeingPlanner.Terminal] { localTerminalFreeing.terminals(in: workspaces) }
    func park(surfaces: [String]) { localTerminalFreeing.park(surfaces) }
    private var localTerminalFreeing: LocalTerminalFreeing { LocalTerminalFreeing(store: machines.local.store, connection: machines.local.connection, canPark: machines.local.supports(DaemonCapability.tabPark.rawValue) && machines.local.supports(DaemonCapability.tabRestartKeptLayout.rawValue)) }
}
